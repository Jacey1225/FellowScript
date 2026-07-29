"""Email content for the two transactional flows: password reset and the
email-based 2FA login code.

Both are "transactional or relationship" messages under CAN-SPAM (15 U.S.C.
Sec. 7702(17)) — they facilitate an already-agreed-upon account/security
action, not advertise anything — so the opt-out and "this is an ad" labeling
requirements don't apply. What still applies regardless of message type, and
is followed here:
  - Truthful, non-misleading sender identity and subject line (no header
    spoofing, no clickbait).
  - A way to reach the sender (SUPPORT_EMAIL below).
A physical postal address is only legally required for commercial mail, but
is included anyway as good practice / deliverability hygiene — see the
SENDER_POSTAL_ADDRESS placeholder, which must be set to a real address
before this goes live.
"""
import html
import os

SUPPORT_EMAIL = os.getenv("SUPPORT_EMAIL", "support@fellowscript.com")
SENDER_POSTAL_ADDRESS = os.getenv(
    "SENDER_POSTAL_ADDRESS",
    "[SENDER_POSTAL_ADDRESS not set — add a real business mailing address to .env before sending real email]",
)

_FOOTER_HTML = f"""
<p style="margin-top:32px;padding-top:16px;border-top:1px solid #e0d5bc;
          font-size:12px;line-height:1.6;color:#8a7a5c;">
  This is a transactional email about your FellowScript account and does not
  contain marketing content. Questions? Contact
  <a href="mailto:{SUPPORT_EMAIL}" style="color:#a3690f;">{SUPPORT_EMAIL}</a>.<br>
  FellowScript &middot; {SENDER_POSTAL_ADDRESS}
</p>
"""

_FOOTER_TEXT = f"""
---
This is a transactional email about your FellowScript account and does not
contain marketing content. Questions? Contact {SUPPORT_EMAIL}.
FellowScript - {SENDER_POSTAL_ADDRESS}
"""


def _wrap_html(preheader: str, body_html: str) -> str:
    return f"""\
<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;background:#f7f2e7;font-family:Georgia,'Times New Roman',serif;">
  <span style="display:none;max-height:0;overflow:hidden;">{preheader}</span>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
    <tr><td align="center" style="padding:32px 16px;">
      <table role="presentation" width="480" cellpadding="0" cellspacing="0"
             style="background:#ffffff;border-radius:12px;padding:32px;">
        <tr><td>
          <h1 style="margin:0 0 20px;font-size:20px;color:#241a0d;">FellowScript</h1>
          {body_html}
          {_FOOTER_HTML}
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>"""


def password_reset_email(reset_link: str) -> tuple[str, str, str]:
    """Returns (subject, html_body, text_body) for the password-reset link email."""
    subject = "Reset your FellowScript password"
    body_html = f"""
      <p style="font-size:15px;line-height:1.6;color:#241a0d;">
        We received a request to reset your FellowScript account password.
      </p>
      <p style="text-align:center;margin:28px 0;">
        <a href="{reset_link}"
           style="background:#a3690f;color:#ffffff;padding:12px 28px;
                  border-radius:8px;text-decoration:none;font-size:15px;">
          Reset your password
        </a>
      </p>
      <p style="font-size:13px;line-height:1.6;color:#6b5d47;">
        This link expires in 30 minutes and can only be used once. If you
        didn't request a password reset, you can safely ignore this email —
        your password will not be changed.
      </p>
    """
    text_body = (
        "We received a request to reset your FellowScript account password.\n\n"
        f"Reset it here (expires in 30 minutes, single use): {reset_link}\n\n"
        "If you didn't request this, you can safely ignore this email — your "
        "password will not be changed."
        + _FOOTER_TEXT
    )
    return subject, _wrap_html("Reset your FellowScript password", body_html), text_body


def mfa_code_email(code: str) -> tuple[str, str, str]:
    """Returns (subject, html_body, text_body) for the 2FA login-code email."""
    subject = f"Your FellowScript verification code is {code}"
    body_html = f"""
      <p style="font-size:15px;line-height:1.6;color:#241a0d;">
        Use this code to finish signing in to FellowScript:
      </p>
      <p style="text-align:center;margin:28px 0;font-size:32px;font-weight:bold;
                letter-spacing:6px;color:#a3690f;">
        {code}
      </p>
      <p style="font-size:13px;line-height:1.6;color:#6b5d47;">
        This code expires in 10 minutes and can only be used once. If you
        didn't just try to log in, someone may have your password — consider
        changing it.
      </p>
    """
    text_body = (
        "Use this code to finish signing in to FellowScript:\n\n"
        f"    {code}\n\n"
        "This code expires in 10 minutes and can only be used once. If you "
        "didn't just try to log in, someone may have your password — "
        "consider changing it."
        + _FOOTER_TEXT
    )
    return subject, _wrap_html(f"Your verification code is {code}", body_html), text_body


def mfa_setup_code_email(code: str) -> tuple[str, str, str]:
    """Returns (subject, html_body, text_body) for confirming an email address
    when a user turns two-factor authentication on (distinct wording from the
    login-time code so it's clear this isn't a login attempt)."""
    subject = f"Confirm two-factor authentication — code {code}"
    body_html = f"""
      <p style="font-size:15px;line-height:1.6;color:#241a0d;">
        Use this code to confirm two-factor authentication on your FellowScript
        account. Once confirmed, we'll email a code like this to sign in.
      </p>
      <p style="text-align:center;margin:28px 0;font-size:32px;font-weight:bold;
                letter-spacing:6px;color:#a3690f;">
        {code}
      </p>
      <p style="font-size:13px;line-height:1.6;color:#6b5d47;">
        This code expires in 10 minutes and can only be used once. If you
        didn't request this, you can ignore this email — two-factor
        authentication will not be enabled.
      </p>
    """
    text_body = (
        "Use this code to confirm two-factor authentication on your "
        "FellowScript account. Once confirmed, we'll email a code like this "
        "to sign in.\n\n"
        f"    {code}\n\n"
        "This code expires in 10 minutes and can only be used once. If you "
        "didn't request this, you can ignore this email — two-factor "
        "authentication will not be enabled."
        + _FOOTER_TEXT
    )
    return subject, _wrap_html(f"Confirm two-factor authentication — {code}", body_html), text_body


def content_report_email(
    report_id: str, reporter_username: str, reported_username: str, reported_user_id: str,
    content_type: str, content_id: str | None, snippet: str, reason: str, detail: str,
) -> tuple[str, str, str]:
    """Returns (subject, html_body, text_body) for the developer-facing report
    alert (Guideline 1.2 — a report must reach the developer with enough
    context to act within 24 hours, without needing a dashboard).

    ``snippet`` is user-generated content and MUST be HTML-escaped before
    interpolation — it's the one field here an attacker fully controls."""
    safe_snippet = html.escape(snippet) if snippet else "(no content — direct user report)"
    safe_detail = html.escape(detail) if detail else "(none provided)"
    subject = f"[Report] {content_type} flagged — action needed within 24h"
    body_html = f"""
      <p style="font-size:14px;line-height:1.6;color:#241a0d;">
        <strong>Reporter:</strong> {html.escape(reporter_username)}<br>
        <strong>Reported user:</strong> {html.escape(reported_username)} ({html.escape(reported_user_id)})<br>
        <strong>Content type:</strong> {html.escape(content_type)}<br>
        <strong>Content ID:</strong> {html.escape(str(content_id)) if content_id else "n/a"}<br>
        <strong>Reason:</strong> {html.escape(reason)}
      </p>
      <p style="font-size:13px;line-height:1.6;color:#6b5d47;">
        <strong>Reporter's note:</strong> {safe_detail}
      </p>
      <p style="font-size:13px;line-height:1.6;color:#241a0d;background:#f7f2e7;
                padding:12px;border-radius:8px;white-space:pre-wrap;">
        {safe_snippet}
      </p>
      <p style="font-size:13px;line-height:1.6;color:#6b5d47;">
        To act: <code>python -m backend.moderation.admin_actions resolve {report_id} --remove-content --eject</code>
      </p>
    """
    text_body = (
        f"Reporter: {reporter_username}\n"
        f"Reported user: {reported_username} ({reported_user_id})\n"
        f"Content type: {content_type}\n"
        f"Content ID: {content_id or 'n/a'}\n"
        f"Reason: {reason}\n"
        f"Reporter's note: {detail or '(none provided)'}\n\n"
        f"Content:\n{snippet or '(no content — direct user report)'}\n\n"
        f"To act: python -m backend.moderation.admin_actions resolve {report_id} --remove-content --eject"
        + _FOOTER_TEXT
    )
    return subject, _wrap_html(subject, body_html), text_body
