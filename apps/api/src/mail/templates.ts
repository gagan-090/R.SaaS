/** Branded transactional emails (House Plating). Plain text is always included for clients that block HTML. */
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

function layout(title: string, body: string, button: { label: string; url: string }, footer: string) {
  return `<!doctype html><html><body style="margin:0;background:#FBF6EC;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#2A211C">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:32px 12px"><tr><td align="center">
<table role="presentation" width="100%" style="max-width:520px;background:#FFFDF8;border:1px solid #E4D8C2;border-radius:20px;padding:32px">
<tr><td style="font-size:12px;letter-spacing:2px;font-weight:700;color:#9A5A00">HOUSE PLATING</td></tr>
<tr><td style="padding-top:16px;font-family:Georgia,'Times New Roman',serif;font-size:28px;font-weight:600;line-height:1.2">${title}</td></tr>
<tr><td style="padding-top:12px;font-size:15px;line-height:1.6;color:#4A3F37">${body}</td></tr>
<tr><td style="padding-top:24px"><a href="${esc(button.url)}" style="display:inline-block;background:#F0A93B;color:#1A0F0C;text-decoration:none;font-weight:700;font-size:16px;padding:14px 28px;border-radius:14px">${esc(button.label)}</a></td></tr>
<tr><td style="padding-top:20px;font-size:12px;line-height:1.5;color:#6F6155">If the button does not work, open this link:<br><a href="${esc(button.url)}" style="color:#6B1F2A;word-break:break-all">${esc(button.url)}</a></td></tr>
<tr><td style="padding-top:24px;border-top:1px solid #E4D8C2;margin-top:24px;font-size:12px;color:#9A8B7C">${footer}</td></tr>
</table></td></tr></table></body></html>`;
}

export function verifyRestaurantEmail(o: { ownerName: string; restaurantName: string; url: string }) {
  const subject = `Activate ${o.restaurantName} on House Plating`;
  const text =
    `Hello ${o.ownerName},\n\n${o.restaurantName} is ready on House Plating. Confirm your email and set your password ` +
    `(link valid for 72 hours):\n\n${o.url}\n\nAfter that, sign in to the restaurant console to add your menu, tables and staff.\n\n` +
    `If you did not expect this email, ignore it.`;
  const html = layout(
    `Welcome, ${esc(o.ownerName)}`,
    `<strong>${esc(o.restaurantName)}</strong> is ready on House Plating. Confirm your email and choose a password — then add your menu, tables and staff from the restaurant console.`,
    { label: 'Confirm email & set password', url: o.url },
    'This link works once and expires in 72 hours. If you did not expect this email, you can ignore it.',
  );
  return { subject, text, html };
}
