import { StepperRail, StickyActionBar, FormSkin } from './forms/index.js';
import React, { useState, useEffect } from 'react';
import { Modal, Input, Button, Typography, DatePicker, Select, Switch } from 'antd';
import { CloseOutlined, PlusOutlined, ScheduleOutlined } from '@ant-design/icons';
import dayjs from 'dayjs';
import VerseSelector from './VerseSelector.jsx';

const { Text } = Typography;
const { TextArea } = Input;

function parseVerseRef(ref) {
  const parts = ref.split('-');
  if (parts.length < 3) return ref;
  const vs = parts[parts.length - 1];
  const ch = parts[parts.length - 2];
  const book = parts.slice(0, parts.length - 2).join(' ');
  return `${book} ${ch}:${vs}`;
}

export default function SessionCreator({
  open, onClose, onCreate, onUpdate, editSession,
  books, chapterCount, verseCount,
}) {
  const isEditing = !!editSession;

  const [step, setStep] = useState(0);
  const [furthest, setFurthest] = useState(0);
  const [showErrors, setShowErrors] = useState(false);
  const [title,        setTitle]        = useState('');
  const [timeStart,    setTimeStart]    = useState('');
  const [timeEnd,      setTimeEnd]      = useState('');
  const [timeStartDay, setTimeStartDay] = useState(null);
  const [duration,     setDuration]     = useState(30);
  const [verses,       setVerses]       = useState([]);
  const [prompts,      setPrompts]      = useState([]);
  const [promptInput,  setPromptInput]  = useState('');
  const [recurring,    setRecurring]    = useState(false);
  const [summarize,    setSummarize]    = useState(false);
  const [loading,      setLoading]      = useState(false);

  // Populate or reset when modal opens
  useEffect(() => {
    if (!open) return;
    if (editSession) {
      setTitle(editSession.title || '');
      setTimeStart(editSession.time_start || '');
      setTimeStartDay(editSession.time_start ? dayjs(editSession.time_start) : null);
      if (editSession.time_start && editSession.time_end) {
        const diffMins = dayjs(editSession.time_end).diff(dayjs(editSession.time_start), 'minute');
        setDuration(Math.max(5, Math.round(diffMins / 5) * 5));
      } else {
        setDuration(30);
      }
      setVerses(editSession.verses || []);
      setPrompts(editSession.prompts || []);
      setRecurring(editSession.recurring || false);
      setSummarize(editSession.summarize || false);
    } else {
      setTitle(''); setTimeStart(''); setTimeEnd('');
      setTimeStartDay(null); setDuration(30); setVerses([]);
      setPrompts([]); setPromptInput(''); setRecurring(false); setSummarize(false);
    }
  }, [open, editSession]);

  useEffect(() => {
    if (timeStartDay && duration) {
      setTimeEnd(timeStartDay.add(duration, 'minute').toISOString());
    } else {
      setTimeEnd('');
    }
  }, [timeStartDay, duration]);

  const handleClose = () => { onClose(); };

  const handleSubmit = async () => {
    if (!title.trim() || !timeStart) return;
    setLoading(true);
    const data = { title: title.trim(), timeStart, timeEnd, verses, prompts, recurring, summarize };
    const ok = isEditing
      ? await onUpdate(editSession.id, data)
      : await onCreate(data);
    setLoading(false);
    if (ok) onClose();
  };

  const handleVerseSelect = (book, ch, vs) => {
    const ref = `${book}-${ch}-${vs}`;
    setVerses(prev => prev.includes(ref) ? prev : [...prev, ref]);
  };

  const removeVerse = (ref) => setVerses(prev => prev.filter(v => v !== ref));

  const addPrompt = () => {
    const trimmed = promptInput.trim();
    if (!trimmed) return;
    setPrompts(prev => [...prev, trimmed]);
    setPromptInput('');
  };

  const removePrompt = (idx) => setPrompts(prev => prev.filter((_, i) => i !== idx));

  const labelStyle = {
    display: 'block', fontSize: '0.72rem',
    color: 'rgba(242,242,242,0.55)', fontFamily: 'inherit', marginBottom: '0.35rem',
  };

  return (
    <FormSkin>
    <Modal
      open={open}
      onCancel={handleClose}
      footer={null}
      title={
        <Text style={{ fontFamily: 'inherit', color: 'var(--parchment)', fontSize: '1rem' }}>
          {isEditing ? 'Edit Session' : 'Schedule'}
        </Text>
      }
      styles={{ body: { paddingTop: '0.8rem' }, header: { textAlign: 'center' } }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>

        <StepperRail steps={['Basics', 'Study', 'Options']} current={step} maxReachable={isEditing ? 2 : furthest} onSelect={(i) => setStep(i)} />

        {/* Title */}
        <div hidden={step !== 0}>
          <Text style={labelStyle}>Session Title</Text>
          <Input
            placeholder="Evening Study"
            value={title}
            onChange={e => setTitle(e.target.value)}
            style={{ fontSize: '0.82rem' }}
          />
        </div>

        {/* Start time + duration — side by side */}
        <div hidden={step !== 0} style={{ display: 'flex', gap: '0.75rem' }}>
          <div style={{ flex: 2 }}>
            <Text style={labelStyle}>Start Time</Text>
            <DatePicker
              showTime={{ format: 'h:mm a', use12Hours: true }}
              format="MMM D, h:mm a"
              style={{ width: '100%' }}
              value={timeStartDay}
              onChange={date => { setTimeStartDay(date); setTimeStart(date ? date.toISOString() : ''); }}
            />
          </div>
          <div style={{ flex: 1 }}>
            <Text style={labelStyle}>Duration</Text>
            <Select
              style={{ width: '100%' }}
              value={duration}
              onChange={setDuration}
              options={Array.from({ length: 36 }, (_, i) => {
                const mins = (i + 1) * 5;
                const h = Math.floor(mins / 60);
                const m = mins % 60;
                return { value: mins, label: h > 0 ? (m > 0 ? `${h}h ${m}m` : `${h}h`) : `${m}m` };
              })}
            />
          </div>
        </div>

        {/* Verses */}
        <div hidden={step !== 1}>
          <Text style={labelStyle}>Verses</Text>
          {verses.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.35rem', marginBottom: '0.5rem' }}>
              {verses.map(ref => (
                <span
                  key={ref}
                  style={{
                    display: 'inline-flex', alignItems: 'center', gap: '0.3rem',
                    padding: '0.2rem 0.5rem',
                    background: 'rgba(255,198,26,0.12)', border: '1px solid rgba(255,255,255,0.15)',
                    borderRadius: 4, fontSize: '0.72rem', color: 'var(--parchment)', fontFamily: 'inherit',
                  }}
                >
                  {parseVerseRef(ref)}
                  <CloseOutlined
                    style={{ fontSize: '0.6rem', cursor: 'pointer', color: 'rgba(255,198,26,0.6)' }}
                    onClick={() => removeVerse(ref)}
                  />
                </span>
              ))}
            </div>
          )}
          <VerseSelector books={books} chapterCount={chapterCount} verseCount={verseCount} onSelect={handleVerseSelect} />
        </div>

        {/* Discussion Prompts */}
        <div hidden={step !== 1}>
          <Text style={labelStyle}>Discussion Prompts</Text>
          {prompts.length > 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '0.3rem', marginBottom: '0.5rem' }}>
              {prompts.map((p, i) => (
                <span
                  key={i}
                  style={{
                    display: 'flex', alignItems: 'flex-start', gap: '0.4rem',
                    padding: '0.3rem 0.5rem',
                    background: 'rgba(255,198,26,0.07)', border: '1px solid rgba(255,255,255,0.12)',
                    borderRadius: 4, fontSize: '0.78rem', color: 'var(--parchment)', fontFamily: 'inherit',
                    lineHeight: 1.5,
                  }}
                >
                  <span style={{ flex: 1 }}>{p}</span>
                  <CloseOutlined
                    style={{ fontSize: '0.58rem', cursor: 'pointer', color: 'rgba(255,198,26,0.5)', marginTop: '0.2rem', flexShrink: 0 }}
                    onClick={() => removePrompt(i)}
                  />
                </span>
              ))}
            </div>
          )}
          <div style={{ display: 'flex', gap: '0.4rem', alignItems: 'flex-end' }}>
            <TextArea
              placeholder="Add a discussion question or prompt…"
              value={promptInput}
              onChange={e => setPromptInput(e.target.value)}
              autoSize={{ minRows: 1, maxRows: 3 }}
              style={{ fontSize: '0.78rem', flex: 1 }}
              onPressEnter={e => { if (!e.shiftKey) { e.preventDefault(); addPrompt(); } }}
            />
            <Button
              icon={<PlusOutlined />}
              onClick={addPrompt}
              disabled={!promptInput.trim()}
              style={{ flexShrink: 0 }}
            />
          </div>
        </div>

        {/* Recurring + Summarize */}
        <div hidden={step !== 2} style={{ display: 'flex', gap: '1.4rem', flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem' }}>
            <Switch size="small" checked={recurring} onChange={setRecurring} />
            <Text style={{ ...labelStyle, marginBottom: 0 }}>Repeat weekly</Text>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem' }}>
            <Switch size="small" checked={summarize} onChange={setSummarize} />
            <Text style={{ ...labelStyle, marginBottom: 0 }}>Summarize</Text>
          </div>
        </div>

        {/* Actions: sticky bar, Back / Next, last step Schedule or Save */}
        {(() => {
          const last = step === 2;
          const titleOk = !!title.trim();
          const canSubmit = titleOk && !!timeStart;
          const label = isEditing ? 'Save Changes' : 'Schedule';
          const goNext = () => {
            if (step === 0 && !(titleOk && timeStart)) { setShowErrors(true); return; }
            setShowErrors(false); setFurthest((f) => Math.max(f, step + 1)); setStep(step + 1);
          };
          return (
            <>
              {showErrors && step === 0 && !titleOk && <p className="ff-error" role="alert">Add a title.</p>}
              <StickyActionBar variant="panel"
                secondaryLabel={step === 0 ? 'Cancel' : 'Back'} onSecondary={() => (step === 0 ? handleClose() : setStep(step - 1))}
                primaryLabel={last || isEditing ? label : 'Next'} saving={loading}
                primaryDisabled={last || isEditing ? !canSubmit : (step === 0 && !(titleOk && timeStart))}
                onPrimary={() => { if (last || isEditing) { if (!canSubmit) { setStep(0); setShowErrors(true); return; } handleSubmit(); } else goNext(); }} />
            </>
          );
        })()}
      </div>
    </Modal>
    </FormSkin>
  );
}
