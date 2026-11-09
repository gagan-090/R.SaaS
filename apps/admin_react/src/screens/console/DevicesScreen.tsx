import { useState } from 'react';
import { Copy, Link2Off, Monitor, RefreshCw, Router, Smartphone } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { ago, shortDate } from '../../lib/format';
import { copyText } from '../../lib/download';
import { titleCase } from '../../lib/labels';
import { useSession } from '../../state/auth';
import { AsyncView } from '../../ui/async';
import { IconButton, PageFrame, SectionCard, SectionHeader, StatusChip } from '../../ui/kit';
import { askReason, showDone, showError } from '../../ui/overlay';

/**
 * T1 Hubs & devices: the branch hub (the cashier device that keeps working offline) and every paired terminal.
 * A hub is added from the POS app itself (the owner's first sign-in); this page shows how, and lets you revoke.
 */
export function DevicesScreen() {
  const me = useSession();
  const email = `${me?.me.email ?? ''}`;
  const [n, setN] = useState(0);

  const revoke = async (d: Json) => {
    const reason = await askReason({ title: `Revoke ${d.name}?`, confirmLabel: 'Revoke', message: 'It stops syncing immediately. To use it again, set it up from the POS app.' });
    if (reason == null) return;
    try {
      await api.revokeDevice(d.id, reason);
      showDone(`${d.name} revoked`);
      setN((x) => x + 1);
    } catch (e) {
      showError(e);
    }
  };

  return (
    <AsyncView deps={[n]} load={() => api.devices()} page="Hubs & devices">
      {(devices) => {
        const active = devices.filter((d) => d.revokedAt == null);
        const revoked = devices.filter((d) => d.revokedAt != null);
        const hub = active.find((d) => d.isHub === true);
        const howTo = <HowTo apiUrl={api.baseUrl} email={email} hasHub={hub != null} />;
        return (
          <PageFrame
            title="Hubs & devices"
            subtitle={hub == null ? 'No hub yet — set one up below' : `Hub: ${hub.name} · ${hub.online === true ? 'online' : `last seen ${ago(hub.lastSeenAt)}`}`}
            actions={<IconButton title="Refresh" icon={RefreshCw} onClick={() => setN((x) => x + 1)} />}
          >
            <div className="stack">
              {/* with a hub in place the device list comes first; a new restaurant sees the setup steps first */}
              {hub == null && howTo}
              {active.length > 0 && (
                <div className="card list">
                  {active.map((d) => (
                    <DeviceRow key={d.id} device={d} onRevoke={() => revoke(d)} />
                  ))}
                </div>
              )}
              {hub != null && howTo}
              {revoked.length > 0 && (
                <div>
                  <SectionHeader title={`Revoked · ${revoked.length}`} />
                  <div className="card list">
                    {revoked.map((d) => (
                      <DeviceRow key={d.id} device={d} />
                    ))}
                  </div>
                </div>
              )}
            </div>
          </PageFrame>
        );
      }}
    </AsyncView>
  );
}

function DeviceRow({ device, onRevoke }: { device: Json; onRevoke?: () => void }) {
  const revoked = device.revokedAt != null;
  const online = device.online === true;
  const Icon = device.isHub === true ? Router : device.platform === 'windows' ? Monitor : Smartphone;
  return (
    <div className="list-row" data-testid={`device-${device.name}`}>
      <span className="icon-tile">
        <Icon size={22} color={revoked ? 'var(--faint)' : 'var(--text)'} aria-hidden />
      </span>
      <div className="grow">
        <div className="wrap" style={{ gap: '4px 8px' }}>
          <span className={`t-label ellipsis${revoked ? ' faint' : ''}`}>{`${device.name}`}</span>
          {device.isHub === true && <StatusChip label="Hub" tone="saffron" />}
          {!revoked && <StatusChip label={online ? 'Online' : 'Offline'} tone={online ? 'success' : 'neutral'} />}
        </div>
        <div className="muted mt-4">
          {revoked
            ? `Revoked ${shortDate(device.revokedAt)}`
            : `${titleCase(`${device.platform}`)} · ${device.branch?.name ?? ''} · paired ${shortDate(device.pairedAt)} · seen ${ago(device.lastSeenAt)}`}
        </div>
      </div>
      {!revoked && onRevoke && <IconButton title="Revoke" icon={Link2Off} onClick={onRevoke} />}
    </div>
  );
}

function HowTo({ apiUrl, email, hasHub }: { apiUrl: string; email: string; hasHub: boolean }) {
  const step = (n: number, title: string, body: React.ReactNode) => (
    <div className="row-top gap-12" style={{ marginBottom: 16 }}>
      <span className="avatar" style={{ width: 28, height: 28, fontSize: 13, background: 'var(--highlight)', color: 'var(--on-highlight)' }}>
        {n}
      </span>
      <div className="grow">
        <div className="t-label">{title}</div>
        <div className="mt-4">{body}</div>
      </div>
    </div>
  );
  return (
    <SectionCard title={hasHub ? 'Add another terminal or replace the hub' : 'Set up your hub'}>
      <p className="muted" style={{ marginTop: 0 }}>
        The hub is the main cashier device (Windows PC or Android). It keeps billing running when the internet drops and syncs to the cloud when it is back. Staff phones and tablets join it over Wi-Fi with their email and PIN.
      </p>
      <div className="mt-16">
        {step(1, 'Install BhojMitra POS on the cashier device', <span className="muted">Android: install the APK. Windows: run the installer.</span>)}
        {step(
          2,
          'Open it on the first device (needs internet once)',
          <>
            <span className="muted">If it asks for a server (Server settings), use this address:</span>
            <div className="copy-box mt-8">
              <span className="t-mono grow" data-testid="hub-api-url" style={{ userSelect: 'all', overflowWrap: 'anywhere' }}>
                {apiUrl}
              </span>
              <IconButton title="Copy" icon={Copy} sm onClick={async () => (await copyText(apiUrl)) && showDone('Address copied')} />
            </div>
          </>,
        )}
        {step(3, 'Sign in as the owner with your password', <span className="muted">{email ? `For example ${email} and your console password. This device becomes the main device.` : 'Use your console email and password. This device becomes the main device.'}</span>)}
        {step(4, 'More devices: email + PIN on the same Wi-Fi', <span className="muted">Add staff (email + PIN). On each new device, open BhojMitra POS on the restaurant Wi-Fi and sign in with that email and PIN — it connects to the main device by itself, also without internet.</span>)}
      </div>
    </SectionCard>
  );
}
