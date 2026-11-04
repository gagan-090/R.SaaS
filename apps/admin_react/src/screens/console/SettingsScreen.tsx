import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import { Check, Lock, Plus, Upload, ImageOff } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { shortDate } from '../../lib/format';
import { pickFile } from '../../lib/download';
import { prepareLogo } from '../../lib/image';
import { featureLabel, statusLabel, toneForStatus } from '../../lib/labels';
import { useSession } from '../../state/auth';
import { bumpBrand, useIsDark, useRestaurantLook } from '../../state/app';
import { brandFromJson, inkOn, onColor, textScale, weightOf } from '../../state/brand';
import { LoadError } from '../../ui/async';
import { Chip, ErrorState, LoadingState, PageFrame, PrimaryButton, SecondaryButton, SectionCard, Segmented, Skeleton, StatusChip, TextButton, TextField } from '../../ui/kit';
import { Dialog, openDialog, showDone, showError } from '../../ui/overlay';

/** Restaurant settings: what prints on every bill (name, address, GSTIN), the plan, GST rates and the restaurant's look. */
export function SettingsScreen() {
  const me = useSession();
  const can = (p: string) => !!me?.can(p);
  const [overview, setOverview] = useState<Json | null>(null);
  const [taxes, setTaxes] = useState<Json[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [name, setName] = useState('');
  const [gstin, setGstin] = useState('');
  const [address, setAddress] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [o, t] = await Promise.all([api.overview(), api.taxRules()]);
      const r = o.restaurant as Json;
      setName(`${r.name ?? ''}`);
      setGstin(`${r.gstin ?? ''}`);
      setAddress(`${r.address ?? ''}`);
      setOverview(o);
      setTaxes(t);
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  const saveProfile = async () => {
    setBusy(true);
    try {
      await api.updateProfile({ name: name.trim(), gstin: gstin.trim() === '' ? null : gstin.trim().toUpperCase(), address: address.trim() === '' ? null : address.trim() });
      showDone('Saved — new bills use these details');
      await load();
    } catch (e) {
      showError(e);
    } finally {
      setBusy(false);
    }
  };

  const addTax = async () => {
    const rate = await openDialog<number>((close) => <TaxDialog close={close} />);
    if (rate == null) return;
    try {
      await api.createTaxRule(`GST ${rate / 100}%`, rate);
      await load();
      showDone(`GST ${rate / 100}% added`);
    } catch (e) {
      showError(e);
    }
  };

  if (error != null) return <LoadError error={error} page="Settings" onRetry={load} />;
  if (overview == null || taxes == null) return <LoadingState />;
  const lic = overview.license as Json;
  const edit = can('restaurant.profile.manage');

  const profile = (
    <SectionCard title="On every bill">
      <div className="col gap-12">
        <TextField label="Restaurant name" value={name} onChange={setName} disabled={!edit} testId="profile-name" />
        <TextField label="GSTIN" placeholder="27AAAPA1234A1Z5" value={gstin} onChange={setGstin} disabled={!edit} upper />
        <TextField label="Address" value={address} onChange={setAddress} disabled={!edit} multiline={2} />
        {edit && (
          <div className="row" style={{ justifyContent: 'flex-end' }}>
            <PrimaryButton label="Save" busy={busy} height={48} onClick={saveProfile} testId="save-profile" />
          </div>
        )}
      </div>
    </SectionCard>
  );
  const plan = (
    <SectionCard title="Your plan">
      <div className="wrap gap-12">
        <span className="t-card" style={{ fontSize: 26 }}>
          {`${lic.planName ?? '—'}`}
        </span>
        <StatusChip label={statusLabel(lic.state)} tone={toneForStatus(`${lic.state}`)} />
      </div>
      <div className="muted mt-4">{lic.endsAt == null ? 'No active license' : `Renews ${shortDate(lic.endsAt)}`}</div>
      <div className="t-overline mt-12">Includes</div>
      <div className="wrap mt-8" style={{ gap: 4 }}>
        {((lic.features ?? []) as string[]).map((f) => (
          <span key={f} className="feature-chip">
            <Check size={16} color="var(--success)" aria-hidden />
            {featureLabel(f)}
          </span>
        ))}
      </div>
    </SectionCard>
  );
  const taxCard = (
    <SectionCard title="GST rates" actions={can('menu.publish') && <TextButton label="Add" icon={Plus} onClick={addTax} />}>
      {taxes.length === 0 ? (
        <span className="muted">No GST rates yet. Adding your first dish creates GST 5%.</span>
      ) : (
        <div className="wrap">
          {taxes.map((t) => (
            <StatusChip key={t.id} label={`${t.name} · CGST ${t.rateBp / 200}% + SGST ${t.rateBp / 200}%`} />
          ))}
        </div>
      )}
    </SectionCard>
  );

  return (
    <PageFrame title="Settings" subtitle="Restaurant details, your look, plan and taxes">
      <div className="cols" style={{ '--cols': '3fr 2fr', alignItems: 'start' } as CSSProperties}>
        {profile}
        <div className="stack">
          {plan}
          {taxCard}
        </div>
      </div>
      <div className="mt-16">
        <BrandingCard />
      </div>
    </PageFrame>
  );
}

function TaxDialog({ close }: { close: (v?: number) => void }) {
  const [rate, setRate] = useState(500);
  return (
    <Dialog
      title="Add a GST rate"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Add" height={56} onClick={() => close(rate)} />
        </>
      }
    >
      <div className="wrap">
        {[0, 500, 1200, 1800, 2800].map((r) => (
          <Chip key={r} label={`${r / 100}%`} on={rate === r} onClick={() => setRate(r)} />
        ))}
      </div>
    </Dialog>
  );
}

/** Ready-made colours; any other colour can be typed as #RRGGBB. */
const brandPresets: [string, string][] = [
  ['#6B1F2A', 'House wine'], ['#C62828', 'Chilli red'], ['#E65100', 'Tandoor orange'], ['#F0A93B', 'Saffron'],
  ['#2E7D32', 'Mint green'], ['#00796B', 'Teal'], ['#1A73E8', 'Blue'], ['#3949AB', 'Indigo'], ['#6A1B9A', 'Plum'], ['#212121', 'Charcoal'],
];

/**
 * Settings → Your look: logo, colour and text style for the console and the POS (plan feature "branding",
 * switched on per plan by the Super Admin). Without it the card says how to get it; the API refuses saves anyway.
 */
function BrandingCard() {
  const me = useSession();
  const edit = !!me?.can('restaurant.profile.manage');
  const look = useRestaurantLook();
  const [data, setData] = useState<Json | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [hex, setHex] = useState('');
  const [textSize, setTextSize] = useState('standard');
  const [weight, setWeight] = useState('bold');
  const [kase, setKase] = useState('normal');
  const [logoId, setLogoId] = useState<string | null>(null);
  const [logoData, setLogoData] = useState<string | null>(null); // just uploaded, shown before the network copy loads
  const [busy, setBusy] = useState(false);
  const [logoBusy, setLogoBusy] = useState(false);
  const [hexError, setHexError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const d = await api.branding();
      const s = (d.saved ?? d.defaults) as Json;
      setData(d);
      setHex(`${s.color}`);
      setTextSize(`${s.textSize}`);
      setWeight(`${s.headingWeight}`);
      setKase(`${s.headingCase}`);
      setLogoId(s.logoImageId ?? null);
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  const draft = brandFromJson({ color: hex.trim(), textSize, headingWeight: weight, headingCase: kase, logoImageId: logoId });

  const save = async () => {
    if (!draft) return setHexError('Use a colour like #1A73E8');
    setBusy(true);
    setHexError(null);
    try {
      await api.setBranding({ color: draft.color, textSize, headingWeight: weight, headingCase: kase });
      bumpBrand();
      showDone('Saved — the POS picks up your look within a minute');
    } catch (e) {
      showError(e);
    } finally {
      setBusy(false);
    }
  };

  const uploadLogo = async () => {
    const f = await pickFile('image/*');
    if (!f) return;
    setLogoBusy(true);
    try {
      const img = await prepareLogo(f);
      const r = await api.setLogo(img.contentType, img.base64);
      setLogoId(r.logoImageId ?? null);
      setLogoData(img.dataUrl);
      bumpBrand();
      showDone('Logo saved');
    } catch (e) {
      showError(e);
    } finally {
      setLogoBusy(false);
    }
  };

  const removeLogo = async () => {
    setLogoBusy(true);
    try {
      await api.removeLogo();
      setLogoId(null);
      setLogoData(null);
      bumpBrand();
      showDone('Logo removed');
    } catch (e) {
      showError(e);
    } finally {
      setLogoBusy(false);
    }
  };

  if (error != null)
    return (
      <SectionCard title="Your look">
        <ErrorState message={`${(error as Error).message ?? error}`} onRetry={load} />
      </SectionCard>
    );
  if (data == null)
    return (
      <SectionCard title="Your look">
        <Skeleton h={120} />
      </SectionCard>
    );
  if (data.enabled !== true) {
    return (
      <SectionCard title="Your look">
        <div className="row-top gap-12" data-testid="branding-locked">
          <Lock size={22} className="muted" aria-hidden />
          <div>
            <div className="t-card">Custom branding is not in your plan</div>
            <p className="muted" style={{ margin: '4px 0 0' }}>
              Ask House Plating to switch on "Custom branding" for your plan. Then you can add your logo, colour and text style, and they appear on this console and on every POS device.
            </p>
          </div>
        </div>
      </SectionCard>
    );
  }

  const logoSrc = logoData ?? (logoId ? api.mediaUrl(logoId) : null);
  const seg = (testId: string, value: string, options: [string, string][], on: (v: string) => void) => <Segmented<string> testId={testId} value={value} options={options} onChange={on} disabled={!edit} />;

  return (
    <SectionCard title="Your look">
      <div className="cols" style={{ '--cols': '1fr 340px', alignItems: 'start' } as CSSProperties}>
        <div className="col gap-8">
          <div className="t-label">Logo</div>
          <div className="row gap-12">
            <div className="center" style={{ width: 140, height: 72, padding: 8, borderRadius: 12, background: 'var(--raised)', border: '1px solid var(--line)', flex: 'none' }}>
              {logoSrc ? <img src={logoSrc} alt="Logo" style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }} /> : <span className="muted">No logo</span>}
            </div>
            {edit && (
              <div className="wrap">
                <SecondaryButton label={logoId == null ? 'Upload logo' : 'Change'} icon={Upload} onClick={logoBusy ? null : uploadLogo} testId="upload-logo" />
                {logoId != null && <TextButton label="Remove" icon={ImageOff} onClick={logoBusy ? null : removeLogo} />}
              </div>
            )}
          </div>
          <span className="muted" style={{ fontSize: 12 }}>
            PNG with a transparent background looks best. Shown in the sidebar and on the POS.
          </span>
          <div className="t-label mt-8">Colour</div>
          <div className="wrap">
            {brandPresets.map(([c, n]) => (
              <button key={c} type="button" title={n} aria-label={n} data-testid={`swatch-${c}`} className={`swatch${hex.toUpperCase() === c ? ' on' : ''}`} style={{ background: c }} disabled={!edit} onClick={() => setHex(c)} />
            ))}
          </div>
          <div style={{ width: 220 }}>
            <TextField
              label="Or type a colour"
              placeholder="#1A73E8"
              value={hex}
              onChange={(v) => (setHex(v), setHexError(null))}
              error={hexError}
              disabled={!edit}
              testId="brand-hex"
              prefix={<span style={{ width: 18, height: 18, borderRadius: '50%', background: draft?.color ?? 'var(--accent)', display: 'inline-block' }} />}
            />
          </div>
          <div className="t-label mt-8">Text size</div>
          {seg('brand-size', textSize, [
            ['compact', 'Small'],
            ['standard', 'Normal'],
            ['large', 'Large'],
          ], setTextSize)}
          <div className="t-label mt-8">Headings</div>
          <div className="wrap gap-12">
            {seg('brand-weight', weight, [
              ['regular', 'Light'],
              ['bold', 'Bold'],
              ['heavy', 'Extra bold'],
            ], setWeight)}
            {seg('brand-case', kase, [
              ['normal', 'Aa'],
              ['upper', 'AA'],
            ], setKase)}
          </div>
          {edit && (
            <div className="mt-16">
              <PrimaryButton label="Save my look" busy={busy} height={48} onClick={save} testId="save-branding" />
            </div>
          )}
        </div>
        <BrandPreview brand={draft} name={look?.name || 'Your restaurant'} logo={logoSrc} />
      </div>
    </SectionCard>
  );
}

/** How the choices look before saving: a mini POS screen in the draft colour and text style. */
function BrandPreview({ brand, name, logo }: { brand: ReturnType<typeof brandFromJson>; name: string; logo: string | null }) {
  const dark = useIsDark();
  const scale = textScale(brand);
  const upper = brand?.headingCase === 'upper';
  const fill = brand?.color ?? '#F0A93B';
  const onFill = onColor(fill);
  const ink = brand ? inkOn(brand.color, dark) : 'var(--accent-ink)';
  return (
    <div data-testid="brand-preview" style={{ padding: 16, borderRadius: 20, background: 'var(--ground)', border: '1px solid var(--line)' }}>
      <div className="t-overline">Preview</div>
      <div className="row mt-12">
        {logo && <img src={logo} alt="" style={{ height: 32, width: 64, objectFit: 'contain' }} />}
        <span className="ellipsis" style={{ fontWeight: weightOf(brand), fontSize: 18 * scale }}>
          {upper ? name.toUpperCase() : name}
        </span>
      </div>
      <div className="row mt-12" style={{ padding: 12, borderRadius: 14, background: 'var(--surface)', border: '1px solid var(--line)' }}>
        <span className="avatar" style={{ width: 32, height: 32, background: fill, color: onFill, fontSize: 14 * scale }}>
          4
        </span>
        <span className="grow" style={{ fontSize: 14 * scale }}>
          Table 4 · 3 items
        </span>
        <span className="t-label" style={{ color: ink, fontSize: 15 * scale }}>
          ₹420
        </span>
      </div>
      <div className="center t-label mt-12" style={{ height: 44, borderRadius: 16, background: fill, color: onFill, fontSize: 15 * scale }}>
        {upper ? 'SEND TO KITCHEN' : 'Send to kitchen'}
      </div>
    </div>
  );
}
