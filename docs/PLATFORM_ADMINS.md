# Platform administrators

## Add an admin directly

Open **Platform console → Admins → Add admin**. Enter name, email and a password of at least 12 characters,
then choose **Create admin**. The account becomes Active immediately; email delivery is not needed.

New accounts start with **Onboarding Admin**, which manages restaurant onboarding and licenses. To assign a different
role, open the account's **Actions → Edit roles**. Administrators can only grant permissions they already hold.

Share the password securely. The new admin signs in with email and password and sets up two-step authentication
on their first sign-in. Passwords are stored as Argon2id hashes and never included in responses or audit logs.

## Finish a pending invitation

For an account shown as **Invited**, open **Actions → Set password & activate**. Enter the password and choose
**Activate admin**. The same account and its assigned roles are retained; its old invitation link is invalidated.
This also works when the invitation expired or its email was never delivered.

The action applies only to invited accounts. It cannot change passwords or MFA for active or disabled admins.

## API

- `POST /api/v1/platform/admins/create`: `name`, `email`, `password`; optional `roleIds` for API clients.
- `POST /api/v1/platform/admins/:id/activate`: `password`.
- Both require `platform.admin.invite`, enforce permission limits, and produce audit events.

The original invitation endpoint remains available for API clients that use email invitations.
