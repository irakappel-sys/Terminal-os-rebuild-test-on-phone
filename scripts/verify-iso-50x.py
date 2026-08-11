#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

CHUNK = 16 * 1024 * 1024


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb", buffering=0) as f:
        while True:
            block = f.read(CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def compare_once(a: Path, b: Path) -> tuple[str, str, int]:
    size_a = a.stat().st_size
    size_b = b.stat().st_size
    if size_a != size_b:
        raise RuntimeError(f"size mismatch: {size_a} != {size_b}")

    ha = hashlib.sha256()
    hb = hashlib.sha256()
    offset = 0

    with a.open("rb", buffering=0) as fa, b.open("rb", buffering=0) as fb:
        while True:
            ba = fa.read(CHUNK)
            bb = fb.read(CHUNK)
            if ba != bb:
                limit = min(len(ba), len(bb))
                mismatch = next((i for i in range(limit) if ba[i] != bb[i]), limit)
                raise RuntimeError(f"byte mismatch at offset {offset + mismatch}")
            if not ba:
                break
            ha.update(ba)
            hb.update(bb)
            offset += len(ba)

    return ha.hexdigest(), hb.hexdigest(), offset


def main() -> int:
    parser = argparse.ArgumentParser(description="Perform repeated full byte-for-byte ISO verification")
    parser.add_argument("image", type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--passes", type=int, default=50)
    parser.add_argument("--expected-sha256")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    image = args.image.resolve()
    if not image.is_file():
        raise SystemExit(f"image not found: {image}")
    if args.passes < 1:
        raise SystemExit("--passes must be >= 1")

    temporary_reference: Path | None = None
    if args.reference:
        reference = args.reference.resolve()
        if not reference.is_file():
            raise SystemExit(f"reference not found: {reference}")
        mode = "external-reference"
    else:
        fd, tmp_name = tempfile.mkstemp(prefix="terminalos-byte-reference-", suffix=".iso")
        os.close(fd)
        temporary_reference = Path(tmp_name)
        with image.open("rb", buffering=0) as src, temporary_reference.open("wb", buffering=0) as dst:
            shutil.copyfileobj(src, dst, length=CHUNK)
            dst.flush()
            os.fsync(dst.fileno())
        reference = temporary_reference
        mode = "independent-copy"

    try:
        initial_image_sha = sha256_file(image)
        initial_reference_sha = sha256_file(reference)
        if initial_image_sha != initial_reference_sha:
            raise SystemExit(
                f"initial SHA-256 mismatch: image={initial_image_sha} reference={initial_reference_sha}"
            )
        if args.expected_sha256 and initial_image_sha.lower() != args.expected_sha256.lower():
            raise SystemExit(
                f"expected SHA-256 mismatch: got={initial_image_sha} expected={args.expected_sha256.lower()}"
            )

        passes: list[dict[str, object]] = []
        expected_size = image.stat().st_size

        for index in range(1, args.passes + 1):
            image_sha, reference_sha, compared = compare_once(image, reference)
            if compared != expected_size:
                raise RuntimeError(f"pass {index}: compared {compared} bytes, expected {expected_size}")
            if image_sha != initial_image_sha or reference_sha != initial_reference_sha:
                raise RuntimeError(f"pass {index}: hash instability detected")
            row = {
                "pass": index,
                "bytes_compared": compared,
                "image_sha256": image_sha,
                "reference_sha256": reference_sha,
                "result": "PASS",
            }
            passes.append(row)
            print(
                f"PASS {index:02d}/{args.passes}: {compared} bytes identical, sha256={image_sha}",
                flush=True,
            )

        report = {
            "result": "PASS",
            "mode": mode,
            "image": str(image),
            "reference": str(reference) if mode == "external-reference" else "independent full copy",
            "passes": args.passes,
            "bytes_per_pass": expected_size,
            "total_bytes_compared": expected_size * args.passes,
            "sha256": initial_image_sha,
            "pass_results": passes,
        }

        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

        print(json.dumps({k: v for k, v in report.items() if k != "pass_results"}, indent=2))
        return 0
    finally:
        if temporary_reference:
            temporary_reference.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(1)
