"""Transactional email delivery via AWS SES.

Uses a dedicated SES-scoped IAM credential (SES_ACCESS_KEY_ID/SES_SECRET_ACCESS_KEY),
kept separate from the existing Chime-SDK IAM user so a leak or misconfiguration
of one never grants access to the other — least-privilege, same reasoning as
storing only opaque Stripe/Apple references instead of raw payment data.

Setup this depends on (not done by this code, must be completed once in the
AWS Console before any email will actually send):
  1. Verify the fellowscript.com domain identity in SES and add the DKIM/SPF
     CNAME records it generates to DNS.
  2. Request SES production access — new accounts start in a sandbox that can
     only deliver to individually-verified addresses.
  3. Create an IAM user/policy scoped to ses:SendEmail only, and put its keys
     in SES_ACCESS_KEY_ID / SES_SECRET_ACCESS_KEY (plus SES_SENDER_EMAIL,
     SES_REGION if not us-east-1).
"""
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

SES_REGION = os.getenv("SES_REGION", "us-east-1")
SES_SENDER_EMAIL = os.getenv("SES_SENDER_EMAIL", "no-reply@fellowscript.com")


class EmailSendError(Exception):
    """Raised when SES rejects or fails to accept a message for delivery."""


def send_email(to_email: str, subject: str, html_body: str, text_body: str) -> None:
    """Send one transactional email. Raises EmailSendError on any failure.

    Callers decide how to surface a failure: a password-reset request should
    log it and still return its generic success response (never reveal via
    timing/errors whether an email address has an account), while a live
    login-time MFA code send should surface a clear error to the user since
    they cannot proceed without the code.
    """
    client = boto3.client(
        "sesv2",
        region_name=SES_REGION,
        aws_access_key_id=os.getenv("SES_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("SES_SECRET_ACCESS_KEY"),
    )
    try:
        client.send_email(
            FromEmailAddress=f"FellowScript <{SES_SENDER_EMAIL}>",
            Destination={"ToAddresses": [to_email]},
            Content={
                "Simple": {
                    "Subject": {"Data": subject, "Charset": "UTF-8"},
                    "Body": {
                        "Html": {"Data": html_body, "Charset": "UTF-8"},
                        "Text": {"Data": text_body, "Charset": "UTF-8"},
                    },
                }
            },
        )
    except ClientError as e:
        logger.error("SES send_email failed for %s: %s", to_email, e)
        raise EmailSendError(str(e)) from e
