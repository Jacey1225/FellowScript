import React, { useEffect, useState, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Layout, Typography, Spin, Alert, Select, DatePicker, Pagination, Tag, Button, Popover,
} from 'antd';
import { RightOutlined, CheckCircleFilled } from '@ant-design/icons';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import relativeTime from 'dayjs/plugin/relativeTime';
import AppNav from '../components/AppNav.jsx';
import DetectionDetailOverlay from '../components/DetectionDetailOverlay.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { useIsDesktopViewport } from '../hooks/useIsDesktopViewport.js';
import { useFocusTrap } from '../hooks/useFocusTrap.js';
import { API } from '../config.js';
import { fsTheme } from '../theme.js';

dayjs.extend(utc);
dayjs.extend(relativeTime);

const { Content } = Layout;
const { Title, Text } = Typography;
const { RangePicker } = DatePicker;

const CARD_STYLE = {
  background: 'rgba(6,4,1,0.88)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 14,
  marginBottom: '1.5rem',
};

// Known CloudWatch log groups this app ships (api/backend/monitoring/watchdog.py::LOG_GROUPS).
const LOG_GROUPS = [
  '/fellowscript/nginx/access',
  '/fellowscript/nginx/error',
  '/fellowscript/syslog',
  '/fellowscript/auth',
  '/fellowscript/app',
];

const PAGE_SIZE = 20;

const MONO_STYLE = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
};

function StatusDot({ status }) {
  if (status === 'diagnosed') {
    return (
      <CheckCircleFilled
        aria-label="Diagnosed"
        title="Diagnosed"
        style={{ color: fsTheme.token.colorSuccess, fontSize: '0.85rem' }}
      />
    );
  }
  return (
    <span
      aria-label="New"
      title="New"
      style={{
        display: 'inline-block', width: 9, height: 9, borderRadius: '50%',
        background: 'var(--gold)',
      }}
    />
  );
}

// Direction C mobile filter strip (design-notes.md §3): pills styled like
// antd Tag.CheckableTag but rendered as real <button>s (per the §4
// accessibility requirement that every tappable chip stays a real button,
// not a `div`/`span` click handler), each meeting the ≥44×44px tap-target
// minimum with ≥8px spacing between pills.
function chipStyle(active) {
  return {
    display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    minHeight: 44, minWidth: 44,
    padding: '0.55rem 0.95rem',
    borderRadius: 999,
    fontFamily: "'Lora', serif",
    fontSize: '0.72rem',
    whiteSpace: 'nowrap',
    flexShrink: 0,
    cursor: 'pointer',
    border: active ? '1px solid rgba(200,134,26,0.45)' : '1px solid rgba(200,134,26,0.12)',
    background: active ? 'rgba(200,134,26,0.22)' : 'rgba(200,134,26,0.06)',
    color: active ? '#E09A30' : 'rgba(200,134,26,0.6)',
  };
}

function shortLogGroupLabel(g) {
  return g.replace(/^\/fellowscript\//, '');
}

const POPOVER_LABEL_STYLE = {
  fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.1em',
  textTransform: 'uppercase', color: 'rgba(244,228,193,0.4)', display: 'block', marginBottom: 4,
};

// The "Time: All" pill's anchored Popover -- Direction C's one still-needed
// overlay-like affordance for the time-range filter, kept local/scoped
// (not a full sheet) so the list stays visible underneath. Reuses the same
// From/To DatePicker fields + dayjs+utc conversion already used by
// Direction A's fullscreen filter overlay, just behind a lighter trigger.
function TimeFilterPopover({ dateRange, onChange }) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef(null);
  useFocusTrap(open, containerRef);

  const from = dateRange ? dateRange[0] : null;
  const to = dateRange ? dateRange[1] : null;
  const hasRange = !!(from && to);

  return (
    <Popover
      trigger="click"
      open={open}
      onOpenChange={setOpen}
      placement="bottomRight"
      content={
        <div
          ref={containerRef}
          style={{ display: 'flex', flexDirection: 'column', gap: '0.7rem', width: 240 }}
          onKeyDown={e => { if (e.key === 'Escape') setOpen(false); }}
        >
          <div>
            <Text style={POPOVER_LABEL_STYLE}>From</Text>
            <DatePicker
              showTime size="large" style={{ width: '100%' }}
              value={from}
              onChange={v => onChange((v || to) ? [v, to] : null)}
            />
          </div>
          <div>
            <Text style={POPOVER_LABEL_STYLE}>To</Text>
            <DatePicker
              showTime size="large" style={{ width: '100%' }}
              value={to}
              onChange={v => onChange((from || v) ? [from, v] : null)}
            />
          </div>
          {hasRange && (
            <Button type="text" size="small" onClick={() => onChange(null)} style={{ alignSelf: 'flex-start', color: 'rgba(200,134,26,0.7)' }}>
              Clear
            </Button>
          )}
        </div>
      }
    >
      <button type="button" aria-pressed={hasRange} style={chipStyle(hasRange)}>
        Time: {hasRange ? 'Custom' : 'All'}
      </button>
    </Popover>
  );
}

function ChipFilterStrip({ logGroup, dateRange, onLogGroupChange, onDateRangeChange }) {
  return (
    <div
      className="admin-chip-strip"
      role="group"
      aria-label="Filter by log group and time range"
      style={{
        position: 'sticky', top: 'var(--nav-h)', zIndex: 5,
        display: 'flex', gap: '0.6rem', overflowX: 'auto',
        padding: '0.75rem 0', marginBottom: '1rem',
      }}
    >
      <button type="button" aria-pressed={!logGroup} onClick={() => onLogGroupChange('')} style={chipStyle(!logGroup)}>
        All
      </button>
      {LOG_GROUPS.map(g => (
        <button
          key={g} type="button" title={g}
          aria-pressed={logGroup === g}
          onClick={() => onLogGroupChange(g)}
          style={chipStyle(logGroup === g)}
        >
          {shortLogGroupLabel(g)}
        </button>
      ))}
      <TimeFilterPopover dateRange={dateRange} onChange={onDateRangeChange} />
    </div>
  );
}

export default function AdminDetections() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const isDesktop = useIsDesktopViewport();

  // `checked` flips true once the first fetch resolves (success or non-auth
  // failure) -- until then this route renders nothing but a blank spinner,
  // per design-notes.md §1, so a non-admin never sees a flash of admin chrome.
  const [checked, setChecked] = useState(false);

  const [items, setItems]   = useState([]);
  const [total, setTotal]   = useState(0);
  const [offset, setOffset] = useState(0);
  const [listLoading, setListLoading] = useState(true);
  const [listError,   setListError]   = useState(null);

  const [logGroup,  setLogGroup]  = useState('');       // '' = all log groups
  const [dateRange, setDateRange] = useState(null);      // [dayjs, dayjs] | null

  // Direction C's mobile "list-overlay drawer" (design-notes.md §3): tapping
  // a row at mobile widths opens detail as a fullscreen overlay on top of
  // this still-mounted list instead of navigating to
  // /admin/detections/:id, so list scroll position is preserved underneath.
  // Per the architecture-accepted URL/deep-link tradeoff, no history.pushState
  // is added -- the URL does not change when this overlay opens.
  const [overlayId,   setOverlayId]   = useState(null);
  const [overlayOpen, setOverlayOpen] = useState(false);

  // Defensive: if the viewport crosses back to desktop while the overlay is
  // open (e.g. rotating a tablet or resizing a browser window), close it --
  // desktop navigates to the routed detail page instead.
  useEffect(() => { if (isDesktop) setOverlayOpen(false); }, [isDesktop]);

  const fetchDetections = useCallback(async () => {
    if (!user) return;
    setListLoading(true);
    setListError(null);
    try {
      const params = new URLSearchParams();
      if (logGroup) params.set('log_group_name', logGroup);
      if (dateRange && dateRange[0] && dateRange[1]) {
        params.set('start_time', dateRange[0].utc().toISOString());
        params.set('end_time', dateRange[1].utc().toISOString());
      }
      params.set('limit', String(PAGE_SIZE));
      params.set('offset', String(offset));

      const res = await fetch(`${API}/monitoring/detections?${params.toString()}`);

      if (res.status === 401) { navigate('/signin', { replace: true }); return; }
      if (res.status === 403) { navigate('/', { replace: true }); return; }

      if (!res.ok) {
        setListError('Could not load detections.');
        return;
      }
      const data = await res.json();
      setItems(data.items || []);
      setTotal(data.total || 0);
    } catch {
      setListError('Could not reach the server.');
    } finally {
      setListLoading(false);
      setChecked(true);
    }
  }, [user, logGroup, dateRange, offset, navigate]);

  useEffect(() => { fetchDetections(); }, [fetchDetections]);

  const clearFilters = () => {
    setLogGroup('');
    setDateRange(null);
    setOffset(0);
  };

  const hasActiveFilters = !!logGroup || !!dateRange;

  const handleRowClick = (item) => {
    if (isDesktop) {
      navigate(`/admin/detections/${item.id}`);
      return;
    }
    setOverlayId(item.id);
    setOverlayOpen(true);
  };

  const handleCloseOverlay = () => setOverlayOpen(false);

  // Blank page + spinner until the gate-fetch resolves -- no partial chrome.
  if (!checked) {
    return (
      <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Spin size="large" />
      </div>
    );
  }

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <AppNav />

      <Content style={{ paddingTop: 'calc(var(--nav-h) + 2.5rem)', paddingBottom: '5rem', paddingLeft: '2rem', paddingRight: '2rem', maxWidth: 900, margin: '0 auto', width: '100%' }}>

        {/* Header */}
        <div style={{ marginBottom: '2rem', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.32em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.2rem' }}>
            CloudWatch error monitoring · debugging agent reports
          </Text>
          <Title level={2} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
            Error Detections
          </Title>
        </div>

        {/* Filter bar (desktop: inline Select + RangePicker, unchanged) /
            chip-filter strip (mobile, Direction C, design-notes.md §3) */}
        {isDesktop ? (
          <div style={{ ...CARD_STYLE, padding: '1.1rem 1.25rem', animationDelay: '0.08s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.9rem', alignItems: 'center' }}>
              <div style={{ minWidth: 220 }}>
                <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.68rem', letterSpacing: '0.16em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: 6 }}>
                  Log group
                </Text>
                <Select
                  value={logGroup}
                  onChange={v => { setLogGroup(v); setOffset(0); }}
                  style={{ width: '100%' }}
                  options={[
                    { value: '', label: 'All log groups' },
                    ...LOG_GROUPS.map(g => ({ value: g, label: g })),
                  ]}
                />
              </div>
              <div style={{ minWidth: 280 }}>
                <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.68rem', letterSpacing: '0.16em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: 6 }}>
                  Time range
                </Text>
                <RangePicker
                  showTime
                  value={dateRange}
                  onChange={v => { setDateRange(v); setOffset(0); }}
                  style={{ width: '100%' }}
                />
              </div>
            </div>
          </div>
        ) : (
          <ChipFilterStrip
            logGroup={logGroup}
            dateRange={dateRange}
            onLogGroupChange={v => { setLogGroup(v); setOffset(0); }}
            onDateRangeChange={v => { setDateRange(v); setOffset(0); }}
          />
        )}

        {/* List */}
        <div style={{ ...CARD_STYLE, padding: listLoading || listError || items.length === 0 ? '1.5rem' : 0, animationDelay: '0.14s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          {listLoading ? (
            <div style={{ textAlign: 'center', padding: '2rem' }}><Spin size="small" /></div>
          ) : listError ? (
            <Alert
              type="error"
              showIcon
              message={listError}
              action={<Button size="small" onClick={fetchDetections}>Retry</Button>}
              style={{ borderRadius: 8 }}
            />
          ) : items.length === 0 ? (
            <div style={{ textAlign: 'center' }}>
              <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.28)', display: 'block', marginBottom: hasActiveFilters ? '0.6rem' : 0 }}>
                No error detections match these filters.
              </Text>
              {hasActiveFilters && (
                <Button type="text" size="small" onClick={clearFilters} style={{ color: 'rgba(200,134,26,0.7)' }}>
                  Clear filters
                </Button>
              )}
            </div>
          ) : isDesktop ? (
            // Direction C desktop feed (design-notes.md §3): CSS Grid with
            // fixed column widths instead of proportional flex, so tags and
            // timestamps line up vertically across every row. Row vertical
            // padding tightens to 0.6rem (from 0.85rem) for a denser feed.
            // Deliberately no inline "mark diagnosed" quick-action or other
            // new row functionality -- explicit restraint per design-notes.md.
            items.map(item => (
              <button
                key={item.id}
                onClick={() => handleRowClick(item)}
                style={{
                  display: 'grid',
                  gridTemplateColumns: '28px 160px 140px 130px 1fr 20px',
                  columnGap: '0.75rem',
                  alignItems: 'center',
                  width: '100%',
                  padding: '0.6rem 1.1rem', borderBottom: '1px solid rgba(200,134,26,0.08)',
                  background: 'transparent', border: 'none', borderTop: 'none', borderLeft: 'none', borderRight: 'none',
                  cursor: 'pointer', textAlign: 'left', color: 'inherit',
                }}
                onMouseEnter={e => { e.currentTarget.style.background = 'rgba(200,134,26,0.06)'; }}
                onMouseLeave={e => { e.currentTarget.style.background = 'transparent'; }}
              >
                <div style={{ display: 'flex', justifyContent: 'center' }}>
                  <StatusDot status={item.status} />
                </div>
                <Tag style={{ justifySelf: 'start', maxWidth: '100%', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {item.log_group_name}
                </Tag>
                <Tag style={{ justifySelf: 'start', maxWidth: '100%', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {item.matched_signal}
                </Tag>
                <Text
                  title={dayjs.utc(item.event_timestamp).toISOString()}
                  style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.5)', whiteSpace: 'nowrap' }}
                >
                  {dayjs(item.event_timestamp).local().format('MMM D, h:mm A')}
                </Text>
                <Text
                  style={{
                    ...MONO_STYLE, fontSize: '0.78rem', color: 'rgba(244,228,193,0.65)',
                    minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  }}
                >
                  {item.message}
                </Text>
                <RightOutlined style={{ color: 'rgba(200,134,26,0.4)', fontSize: '0.7rem' }} />
              </button>
            ))
          ) : (
            // Direction C mobile row: falls back to Direction A's exact
            // two-line row spec verbatim (design-notes.md §3) -- the
            // CSS-grid columnar layout has no width budget at this
            // breakpoint. Status dot + Log Group tag + relative timestamp
            // on line 1; demoted Matched Signal chip + message preview on
            // line 2. min-height 64px, well above the 44px tap-target floor.
            items.map(item => (
              <button
                key={item.id}
                onClick={() => handleRowClick(item)}
                style={{
                  display: 'flex', alignItems: 'center', gap: '0.5rem', width: '100%',
                  minHeight: 64, padding: '0.75rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.08)',
                  background: 'transparent', border: 'none', borderTop: 'none', borderLeft: 'none', borderRight: 'none',
                  cursor: 'pointer', textAlign: 'left', color: 'inherit',
                }}
              >
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '0.5rem' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', minWidth: 0 }}>
                      <StatusDot status={item.status} />
                      <Tag style={{ flexShrink: 0 }}>{item.log_group_name}</Tag>
                    </div>
                    <Text
                      title={dayjs.utc(item.event_timestamp).toISOString()}
                      style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', color: 'rgba(244,228,193,0.45)', flexShrink: 0, whiteSpace: 'nowrap' }}
                    >
                      {dayjs(item.event_timestamp).fromNow()}
                    </Text>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', marginTop: '0.3rem' }}>
                    <span style={{
                      fontSize: '0.62rem', padding: '2px 6px', borderRadius: 4,
                      background: 'rgba(200,134,26,0.08)', color: 'rgba(200,134,26,0.6)', flexShrink: 0,
                    }}>
                      {item.matched_signal}
                    </span>
                    <Text
                      style={{
                        ...MONO_STYLE, fontSize: '0.76rem', color: 'rgba(244,228,193,0.6)',
                        flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                      }}
                    >
                      {item.message}
                    </Text>
                  </div>
                </div>
                <RightOutlined style={{ color: 'rgba(200,134,26,0.4)', fontSize: '0.6rem', flexShrink: 0 }} />
              </button>
            ))
          )}
        </div>

        {/* Pagination */}
        {!listLoading && !listError && total > 0 && (
          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <Pagination
              current={Math.floor(offset / PAGE_SIZE) + 1}
              pageSize={PAGE_SIZE}
              total={total}
              onChange={page => setOffset((page - 1) * PAGE_SIZE)}
              showTotal={(t, range) => `${range[0]}–${range[1]} of ${t}`}
            />
          </div>
        )}
      </Content>

      {/* Direction C mobile "list-overlay drawer" (design-notes.md §3):
          always mounted -- like Reader.jsx's mobile overlays -- so the
          .mobile-overlay CSS transition works; `.mobile-overlay { display:
          none }` outside the (max-width: 1024px) breakpoint keeps this
          invisible/inert on desktop regardless of `overlayOpen`. */}
      <DetectionDetailOverlay id={overlayId} open={overlayOpen} onClose={handleCloseOverlay} />
    </Layout>
  );
}
