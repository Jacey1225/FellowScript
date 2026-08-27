# Chime session-call IAM policy — `FellowScriptCloudWatchRole`

Produced by the security gate of `.claude/pipeline/20260827-chime-create-meeting-iam-fix/` (step 2).
This is a **specification + deliverable document only** — no AWS change has been applied. Applying
it to live infrastructure is an out-of-band, human-confirmed action (see "Applying this" below).

## The gap

`api/routes/messaging.py` and `api/routes/devotion.py` both construct
`boto3.client("chime-sdk-meetings", region_name="us-east-1")` with no explicit credentials, so the
call resolves through boto3's default credential chain. On the production EC2 host this chain
resolves to the instance profile role, `FellowScriptCloudWatchRole` — confirmed directly by the
reported error's own identity ARN:

```
User: arn:aws:sts::335651423109:assumed-role/FellowScriptCloudWatchRole/i-055f29109661cd2d6
is not authorized to perform: chime:CreateMeeting
on resource: arn:aws:chime:us-east-1:335651423109:meeting/*
because no identity-based policy allows the chime:CreateMeeting action
```

That role currently has no `chime:*` grants, so every `create_meeting`/`create_attendee` call fails.

## Action namespace — resolved, not guessed

The open question in the intake spec ("does `chime-sdk-meetings` map to `chime:` or
`chime-sdk-meetings:` IAM actions?") is answered directly by the production AccessDenied message
above: AWS itself evaluated the `create_meeting` call against the **`chime:CreateMeeting`** action
and the **`arn:aws:chime:us-east-1:335651423109:meeting/*`** resource ARN. This is authoritative —
it is AWS's own live authorization decision, not documentation that could be stale. The policy below
uses the `chime:` namespace and the `chime:...:meeting/*` resource pattern accordingly.

## Exact code usage (confirmed via `grep`, no other Chime call sites exist)

| Call | Call sites |
|---|---|
| `chime.create_meeting(...)` | `messaging.py::_get_or_create_meeting`, `devotion.py::join_call` |
| `chime.create_attendee(...)` | `messaging.py::_create_attendee`, `devotion.py::join_call` |
| `chime.get_meeting(...)` | none — no call site exists anywhere in `api/` |
| `chime.delete_meeting(...)` | none — no call site exists anywhere in `api/` |

## Recommended policy — least privilege, matches actual usage only

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FellowScriptChimeSessionMeetings",
      "Effect": "Allow",
      "Action": [
        "chime:CreateMeeting",
        "chime:CreateAttendee"
      ],
      "Resource": "arn:aws:chime:us-east-1:335651423109:meeting/*"
    }
  ]
}
```

This is scoped to exactly the two actions the code calls today, and to the region/account-scoped
meeting resource pattern AWS itself used in the AccessDenied evaluation (not `Resource: "*"`, not
`chime:*`). It unblocks the reported bug and satisfies the acceptance criteria ("CreateMeeting,
CreateAttendee at minimum both succeed").

### `chime:GetMeeting` / `chime:DeleteMeeting` — deliberately NOT included

The intake spec asked whether the "full session/call lifecycle" (including cleanup) should be
granted now. Recommendation: **no, not yet** — grant these only when a corresponding code path
exists to use them:

- No route or helper anywhere in `api/` calls `get_meeting` or `delete_meeting` today (confirmed by
  repo-wide search). Granting IAM actions nothing in the code exercises is an unused-permission
  least-privilege violation for no offsetting benefit, and it would grant an EC2 instance role that
  already spans CloudWatch + Chime creation the additional ability to delete arbitrary live meetings
  by ID with no code path currently constraining that.
- This does mean Chime SDK meetings created by this backend are never explicitly torn down
  server-side (they age out via Chime's own idle-meeting expiry instead). That's a pre-existing gap,
  not something this fix introduces — flagged here as a follow-up, not resolved in this task.
- **Follow-up condition**: when a `call-end` / session-cleanup code path is added that calls
  `chime.delete_meeting(...)`, extend the `Action` list above with `chime:DeleteMeeting` (and
  `chime:GetMeeting` if a pre-delete existence check is added) in the same statement, at that time —
  do not pre-grant now.

## The "Chime-SDK IAM user" vs. instance-role discrepancy — resolved

`api/backend/email/ses_client.py`'s docstring says its SES credential is "kept separate from the
existing Chime-SDK IAM user," implying Chime SDK calls run under a dedicated IAM **user**
(access-key pair). Separately, `docs/architecture/docker-plan.md`'s secrets table asserts as
"Confirmed" that Chime's boto3 client resolves via a file-based `~/.aws/credentials` profile
belonging to that same dedicated IAM user, distinct from `FellowScriptCloudWatchRole`.

The production error this task is fixing directly contradicts that: it shows the Chime call
resolving to the **assumed-role** identity `FellowScriptCloudWatchRole`, not any IAM-user access-key
identity. boto3's default credential chain checks environment variables, then a shared credentials
file, before falling back to the EC2 instance-metadata role — so this resolution path is only
possible if the described `~/.aws/credentials` file is now absent, empty, or invalid on the current
production host (or never was populated with a working default-profile key pair there in the first
place). Either way, on production **today**, Chime SDK calls run under `FellowScriptCloudWatchRole`,
full stop — that is what the live AccessDenied error proves, and it's what the fix in this task
targets.

Resolution: **extend `FellowScriptCloudWatchRole`'s policy** (per the "Recommended policy" above) —
do not wait on or assume a separate Chime-SDK IAM user is actually in effect on production, because
the error message proves it currently is not. The `ses_client.py` docstring and
`docker-plan.md`'s secrets table are both now known to be **stale/inaccurate** for the Chime
credential-resolution claim specifically (the SES-credential-separation reasoning in `ses_client.py`
itself remains valid and unaffected). Correcting those two docs is a small, low-risk follow-up;
not resolving it here is acceptable since it's documentation-only and doesn't block this fix,
but it should be tracked so the docs don't keep asserting something the live system contradicts.

## No IaC exists for this role

Confirmed by repo-wide search: no Terraform, CDK, CloudFormation, SAM, or other IaC directory exists
anywhere in this repo. `FellowScriptCloudWatchRole`'s policy is managed entirely out-of-band via AWS
Console or CLI, not tracked in version control. This document is therefore the closest thing to an
IaC record this repo has for this specific grant — keep it up to date if the policy changes again.

## Applying this — out-of-band, human-confirmed action, NOT auto-executed

Nothing in this pipeline run applies this policy to live AWS. A human with IAM write access must run
one of the following against the real `FellowScriptCloudWatchRole` role and confirm it succeeded
(e.g. via `aws iam get-role-policy` or a real end-to-end call test) before the acceptance criteria
can be considered met in production:

**Option A — inline role policy (simplest, matches "one narrow grant on one role"):**

```bash
aws iam put-role-policy \
  --role-name FellowScriptCloudWatchRole \
  --policy-name FellowScriptChimeSessionMeetings \
  --policy-document file://chime-session-policy.json
```

(where `chime-session-policy.json` contains the JSON block above.)

**Option B — standalone managed policy (if this project prefers reusable/versioned managed
policies over inline ones — check existing convention on the live role before choosing):**

```bash
aws iam create-policy \
  --policy-name FellowScriptChimeSessionMeetings \
  --policy-document file://chime-session-policy.json

aws iam attach-role-policy \
  --role-name FellowScriptCloudWatchRole \
  --policy-arn arn:aws:iam::335651423109:policy/FellowScriptChimeSessionMeetings
```

Either option should be reviewed against whatever policies are already attached to
`FellowScriptCloudWatchRole` in the console first, to avoid duplicating an existing statement or
conflicting with an existing policy name.
