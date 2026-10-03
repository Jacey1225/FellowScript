#!/usr/bin/env python3
"""Read-mostly live probe for the listing-media IAM statements (never changes IAM).

Run it INSIDE the production container with the app's own credentials (the same
method as the 20260923 delete probe), by the owner or with the owner approving
each command. No pipeline gate runs it. It is a go-live check recorded as A1b.

    python probe_listings_iam.py --bucket "$S3_BUCKET_NAME" --region "$S3_REGION" \
        [--group-photo-key group-photos/<group>/<user>/<file>]

Checks (each printed as one JSON line; exit status is non-zero if any fails):
  identity               sts GetCallerIdentity answers (prints the user name only)
  put/head/get/delete    a 1x1 PNG at listings/_probe/<uuid>.png, deleted afterwards
  presigned POST + GET   round trip over HTTPS with the exact Content-Type condition
  list listings/         ListObjectsV2 with prefix listings/ succeeds
  list attachments/      DENIED (least privilege: ListBucket is only granted for listings/)
  read group photo       optional: GetObject on one real group-photos key (re-encode source)
  delete probe keys      DeleteObject on non-existent keys under group-photos/_probe/ and
                         group-announcements/_probe/ answers success

Only disposable keys under listings/_probe/, group-photos/_probe/ and
group-announcements/_probe/ are touched. It never prints a credential or an object body.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.request
import uuid

PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)
DENIED = {"AccessDenied", "403", "Forbidden", "AllAccessDisabled"}


def _code(exc) -> str:
    return str(getattr(exc, "response", {}).get("Error", {}).get("Code", type(exc).__name__))


def _check(results: list, name: str, fn, *, expect_denied: bool = False) -> None:
    try:
        detail = fn()
        ok = not expect_denied
        results.append({"check": name, "pass": ok, "detail": detail or ("unexpectedly allowed" if expect_denied else "ok")})
    except Exception as exc:  # noqa: BLE001 - every failure is a probe result, not a crash
        code = _code(exc)
        ok = expect_denied and code in DENIED
        results.append({"check": name, "pass": ok, "detail": code})


def run_probe(s3, sts, bucket: str, group_photo_key: str | None = None, http_post=None, http_get=None) -> list[dict]:
    results: list[dict] = []
    key = f"listings/_probe/{uuid.uuid4()}.png"

    _check(results, "identity", lambda: sts.get_caller_identity()["Arn"].rsplit("/", 1)[-1])

    def crud():
        s3.put_object(Bucket=bucket, Key=key, Body=PNG_1X1, ContentType="image/png")
        head = s3.head_object(Bucket=bucket, Key=key)
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        s3.delete_object(Bucket=bucket, Key=key)
        if head["ContentLength"] != len(PNG_1X1) or body != PNG_1X1:
            raise RuntimeError("round trip mismatch")
        return "ok"

    _check(results, "put/head/get/delete listings/_probe", crud)

    def presigned():
        pkey = f"listings/_probe/{uuid.uuid4()}.png"
        post = s3.generate_presigned_post(
            Bucket=bucket, Key=pkey, Fields={"Content-Type": "image/png"},
            Conditions=[{"Content-Type": "image/png"}, ["content-length-range", 1, 1024]], ExpiresIn=60,
        )
        try:
            (http_post or _http_post)(post["url"], post["fields"], PNG_1X1)
            url = s3.generate_presigned_url(
                "get_object", Params={"Bucket": bucket, "Key": pkey, "ResponseContentType": "image/png"}, ExpiresIn=60)
            if not url.startswith("https://"):
                raise RuntimeError("presigned GET is not https")
            if (http_get or _http_get)(url) != PNG_1X1:
                raise RuntimeError("presigned GET body mismatch")
        finally:
            s3.delete_object(Bucket=bucket, Key=pkey)
        return "ok"

    _check(results, "presigned POST + GET round trip", presigned)
    _check(results, "list listings/", lambda: f"keys={s3.list_objects_v2(Bucket=bucket, Prefix='listings/', MaxKeys=1)['KeyCount']}")
    _check(results, "list attachments/ is denied", lambda: s3.list_objects_v2(Bucket=bucket, Prefix="attachments/", MaxKeys=1) and None,
           expect_denied=True)
    if group_photo_key:
        if not group_photo_key.startswith("group-photos/") or ".." in group_photo_key:
            results.append({"check": "read group photo", "pass": False, "detail": "key must start with group-photos/"})
        else:
            _check(results, "read group photo", lambda: (s3.head_object(Bucket=bucket, Key=group_photo_key), s3.get_object(
                Bucket=bucket, Key=group_photo_key)["Body"].read(1))[0] and "ok")
    for prefix in ("group-photos", "group-announcements"):
        _check(results, f"delete under {prefix}/_probe", lambda p=prefix: s3.delete_object(
            Bucket=bucket, Key=f"{p}/_probe/{uuid.uuid4()}.png") and "ok")
    return results


def _http_post(url: str, fields: dict, body: bytes) -> None:
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="p.png"\r\n'
                 "Content-Type: image/png\r\n\r\n".encode() + body + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(url, data=b"".join(parts), method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310 - https URL from our own presign
        if resp.status not in (200, 201, 204):
            raise RuntimeError(f"POST status {resp.status}")


def _http_get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=20) as resp:  # noqa: S310
        return resp.read()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--group-photo-key", default=None)
    args = parser.parse_args(argv)
    import boto3
    from botocore.config import Config

    cfg = Config(s3={"addressing_style": "virtual"}, signature_version="s3v4")
    s3 = boto3.client("s3", region_name=args.region, config=cfg)
    sts = boto3.client("sts", region_name=args.region)
    results = run_probe(s3, sts, args.bucket, args.group_photo_key)
    for r in results:
        print(json.dumps(r))
    ok = all(r["pass"] for r in results)
    print(json.dumps({"summary": "pass" if ok else "fail", "checks": len(results)}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
