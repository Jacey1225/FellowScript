"""Tests for task 20261002-explorer-listing-media, step 2 (testing): the go-live IAM
probe ops/aws/probe_listings_iam.py against a STUB boto3 client (no AWS, never run live).

Properties proved:
  1. Pass path: every check passes, exit status 0, summary line says pass.
  2. Fail paths: a denied PutObject, a presigned round-trip mismatch, ListBucket on
     attachments/ unexpectedly allowed (least privilege broken), a failed identity
     call, an unreadable group photo, each flip the matching check to fail and exit 1.
  3. Only disposable keys are touched: listings/_probe/, group-photos/_probe/,
     group-announcements/_probe/ (plus the one operator-supplied group-photos key,
     read-only); no other key is put, deleted or presigned.
  4. A --group-photo-key outside group-photos/ (or with '..') is refused without any
     S3 call; nothing prints a credential or an object body.
  5. ops/aws/listings_iam_policy.json is valid JSON with exactly the three expected
     statements, scoped to listings/*, ListBucket prefix-conditioned, and no wildcard
     resource or action.

Scratch DB only (port 55432 asserted first). No AWS credentials are used.
Run with: cd api && ../.venv/bin/python tests/test_listings_media_probe.py
"""
import _pathfix  # noqa: F401

import contextlib
import importlib.util
import io
import json
import os
import sys

from botocore.exceptions import ClientError

from _lm_common import REPO_DIR, check, finish, require_scratch_db, StubS3

PROBE_PATH = os.path.join(REPO_DIR, "ops", "aws", "probe_listings_iam.py")
spec = importlib.util.spec_from_file_location("probe_listings_iam", PROBE_PATH)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

ALLOWED = ("listings/_probe/", "group-photos/_probe/", "group-announcements/_probe/")


def err(code, op="Op"):
    return ClientError({"Error": {"Code": code, "Message": code}}, op)


class ProbeS3:
    def __init__(self, deny_put=False, allow_attachments_list=False, corrupt_get=False, group_photo_ok=True):
        self.store, self.calls = {}, []
        self.deny_put, self.allow_attachments_list = deny_put, allow_attachments_list
        self.corrupt_get, self.group_photo_ok = corrupt_get, group_photo_ok

    def put_object(self, Bucket, Key, Body, ContentType=None):
        self.calls.append(("put", Key))
        if self.deny_put:
            raise err("AccessDenied")
        self.store[Key] = Body

    def head_object(self, Bucket, Key):
        self.calls.append(("head", Key))
        if Key.startswith("group-photos/") and not Key.startswith("group-photos/_probe/"):
            if not self.group_photo_ok:
                raise err("AccessDenied")
            return {"ContentLength": 10}
        return {"ContentLength": len(self.store[Key])}

    def get_object(self, Bucket, Key):
        self.calls.append(("get", Key))
        if Key.startswith("group-photos/") and not self.group_photo_ok:
            raise err("AccessDenied")
        body = b"corrupt" if self.corrupt_get else self.store.get(Key, b"photo-bytes")
        return {"Body": io.BytesIO(body)}

    def delete_object(self, Bucket, Key):
        self.calls.append(("delete", Key))
        self.store.pop(Key, None)
        return {}

    def list_objects_v2(self, Bucket, Prefix, MaxKeys=1):
        self.calls.append(("list", Prefix))
        if Prefix.startswith("attachments/") and not self.allow_attachments_list:
            raise err("AccessDenied", "ListObjectsV2")
        return {"KeyCount": 0}

    def generate_presigned_post(self, Bucket, Key, Fields, Conditions, ExpiresIn):
        self.calls.append(("presign_post", Key))
        return {"url": "https://bucket.s3.us-west-1.amazonaws.com/", "fields": {"key": Key, **Fields}}

    def generate_presigned_url(self, op, Params, ExpiresIn):
        self.calls.append(("presign_get", Params["Key"]))
        return f"https://bucket.s3.us-west-1.amazonaws.com/{Params['Key']}?X-Amz-Signature=abc"


class STS:
    def __init__(self, fail=False):
        self.fail = fail

    def get_caller_identity(self):
        if self.fail:
            raise err("InvalidClientTokenId", "GetCallerIdentity")
        return {"Arn": "arn:aws:iam::123456789012:user/fellowscript-app", "Account": "123456789012"}


def http_pair(s3, mismatch=False):
    def post(url, fields, body):
        s3.store[fields["key"]] = body

    def get(url):
        key = url.split(".amazonaws.com/")[1].split("?")[0]
        return b"WRONG" if mismatch else s3.store[key]
    return post, get


def run(s3=None, sts=None, mismatch=False, gp=None):
    s3 = s3 or ProbeS3()
    post, get = http_pair(s3, mismatch)
    return s3, probe.run_probe(s3, sts or STS(), "bkt", gp, http_post=post, http_get=get)


def by_name(results):
    return {r["check"]: r for r in results}


def touched(s3):
    return [k for op, k in s3.calls if op in ("put", "delete", "presign_post", "presign_get")]


def main():
    require_scratch_db()
    print("pass path")
    s3, res = run()
    check("every check passes", all(r["pass"] for r in res), [r for r in res if not r["pass"]])
    names = by_name(res)
    for n in ("identity", "put/head/get/delete listings/_probe", "presigned POST + GET round trip", "list listings/",
              "list attachments/ is denied", "delete under group-photos/_probe", "delete under group-announcements/_probe"):
        check(f"check present: {n}", n in names, list(names))
    check("identity prints the user name only, not the ARN/account", names["identity"]["detail"] == "fellowscript-app" and "123456789012" not in json.dumps(res))
    check("the probe object is deleted afterwards (nothing left under listings/_probe/)", not [k for k in s3.store if k.startswith("listings/_probe/")], s3.store.keys())
    check("only disposable _probe keys were written, deleted or presigned", all(k.startswith(ALLOWED) for k in touched(s3)), touched(s3))
    check("the denied list on attachments/ was exercised", ("list", "attachments/") in s3.calls)

    print("fail paths")
    _, res = run(s3=ProbeS3(deny_put=True))
    check("PutObject denied -> crud check fails", not by_name(res)["put/head/get/delete listings/_probe"]["pass"], by_name(res)["put/head/get/delete listings/_probe"])
    _, res = run(mismatch=True)
    check("presigned GET returning other bytes -> round-trip check fails", not by_name(res)["presigned POST + GET round trip"]["pass"], by_name(res)["presigned POST + GET round trip"])
    s3b, res = run(s3=ProbeS3())
    s3c = ProbeS3(allow_attachments_list=True)
    _, res = run(s3=s3c)
    check("ListBucket on attachments/ unexpectedly allowed -> least-privilege check FAILS", not by_name(res)["list attachments/ is denied"]["pass"], by_name(res)["list attachments/ is denied"])
    _, res = run(sts=STS(fail=True))
    check("STS failure -> identity check fails (credentials not usable)", not by_name(res)["identity"]["pass"])
    s3d = ProbeS3(group_photo_ok=False)
    _, res = run(s3=s3d, gp="group-photos/g/u/p.jpg")
    check("unreadable group photo -> 'read group photo' fails", not by_name(res)["read group photo"]["pass"], by_name(res).get("read group photo"))
    s3e = ProbeS3()
    _, res = run(s3=s3e, gp="group-photos/g/u/p.jpg")
    check("readable group photo -> passes, read-only (no put/delete on it)", by_name(res)["read group photo"]["pass"]
          and not any(op in ("put", "delete") and k == "group-photos/g/u/p.jpg" for op, k in s3e.calls), s3e.calls)
    for bad in ("attachments/x.jpg", "group-photos/../attachments/x.jpg", "listings/x.jpg", ""):
        s3f = ProbeS3()
        if not bad:
            continue
        _, res = run(s3=s3f, gp=bad)
        check(f"--group-photo-key {bad!r} is refused with no S3 call for it", not by_name(res)["read group photo"]["pass"] and not any(k == bad for _op, k in s3f.calls), s3f.calls)

    print("main(): exit codes and output")
    import boto3

    real_client = boto3.client
    real_post, real_get = probe._http_post, probe._http_get
    try:
        for label, s3, sts, want in (("all good", ProbeS3(), STS(), 0), ("a failing check", ProbeS3(allow_attachments_list=True), STS(), 1),
                                    ("sts down", ProbeS3(), STS(fail=True), 1)):
            post, get = http_pair(s3)
            probe._http_post, probe._http_get = post, get
            boto3.client = lambda name, *a, s3=s3, sts=sts, **k: s3 if name == "s3" else sts
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = probe.main(["--bucket", "bkt", "--region", "us-west-1"])
            out = buf.getvalue()
            lines = [json.loads(l) for l in out.strip().splitlines()]
            check(f"{label}: exit status {want}", code == want, code)
            check(f"{label}: summary line matches", lines[-1]["summary"] == ("pass" if want == 0 else "fail"), lines[-1])
            check(f"{label}: output is JSON lines with no credential or object body", "AKIA" not in out and "secret" not in out.lower() and "PNG" not in out)
    finally:
        boto3.client = real_client
        probe._http_post, probe._http_get = real_post, real_get
    code = None
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            probe.main([])
    except SystemExit as e:
        code = e.code
    check("missing --bucket/--region is a usage error (exit 2)", code == 2, code)
    src = open(PROBE_PATH).read()
    check("the probe never creates or changes IAM (no iam client, no policy mutation calls)", "boto3.client(\"iam\"" not in src and "put_user_policy" not in src and "attach_" not in src and "create_policy" not in src)
    check("the probe has no hard-coded credentials", "AKIA" not in src and "aws_secret_access_key" not in src.lower())

    print("IAM policy file")
    pol = json.load(open(os.path.join(REPO_DIR, "ops", "aws", "listings_iam_policy.json")))
    st = {s["Sid"]: s for s in pol["Statement"]}
    check("exactly three statements", len(pol["Statement"]) == 3 and len(st) == 3, list(st))
    media = st["FellowScriptListingMedia"]
    check("listing media: Get/Put/Delete on listings/* only", sorted(media["Action"]) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
          and media["Resource"].endswith("/listings/*") and media["Effect"] == "Allow")
    sweep = st["FellowScriptListingSweep"]
    check("sweep: ListBucket with an s3:prefix = listings/* condition", sweep["Action"] == "s3:ListBucket" and sweep["Condition"]["StringLike"]["s3:prefix"] == ["listings/*"] and not sweep["Resource"].endswith("*"))
    gm = st["FellowScriptGroupMediaDelete"]
    check("group media: DeleteObject only, on group-photos/* and group-announcements/*", gm["Action"] == "s3:DeleteObject"
          and sorted(r.rsplit("/", 1)[1] for r in gm["Resource"]) == ["*", "*"] and {r.rsplit("/", 2)[1] for r in gm["Resource"]} == {"group-photos", "group-announcements"})
    check("no statement uses a wildcard action or a bucket-wide object resource", all(
        a != "*" and not a.endswith(":*") for s in pol["Statement"] for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"]))
        and all(not r.endswith(":::" + r.split(":::")[1].split("/")[0] + "/*") for s in pol["Statement"] for r in ([s["Resource"]] if isinstance(s["Resource"], str) else s["Resource"])))
    check("no statement mentions attachments/ (least privilege)", "attachments" not in json.dumps(pol))
    finish()


if __name__ == "__main__":
    main()
