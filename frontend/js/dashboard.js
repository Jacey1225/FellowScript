import { API, user } from './config.js';

// ── Daily verses dataset ──────────────────────────────────────────────────────

const DAILY_VERSES = [
  { text: "For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life.", ref: "John 3:16" },
  { text: "I can do all things through him who strengthens me.", ref: "Philippians 4:13" },
  { text: "For I know the plans I have for you, declares the Lord, plans for welfare and not for evil, to give you a future and a hope.", ref: "Jeremiah 29:11" },
  { text: "Trust in the Lord with all your heart, and do not lean on your own understanding. In all your ways acknowledge him, and he will make straight your paths.", ref: "Proverbs 3:5–6" },
  { text: "And we know that for those who love God all things work together for good, for those who are called according to his purpose.", ref: "Romans 8:28" },
  { text: "Fear not, for I am with you; be not dismayed, for I am your God; I will strengthen you, I will help you, I will uphold you with my righteous right hand.", ref: "Isaiah 41:10" },
  { text: "Be strong and courageous. Do not be frightened, and do not be dismayed, for the Lord your God is with you wherever you go.", ref: "Joshua 1:9" },
  { text: "The Lord is my shepherd; I shall not want.", ref: "Psalm 23:1" },
  { text: "Come to me, all who labor and are heavy laden, and I will give you rest.", ref: "Matthew 11:28" },
  { text: "Do not be conformed to this world, but be transformed by the renewal of your mind, that by testing you may discern what is the will of God.", ref: "Romans 12:2" },
  { text: "For God gave us a spirit not of fear but of power and love and self-control.", ref: "2 Timothy 1:7" },
  { text: "But the fruit of the Spirit is love, joy, peace, patience, kindness, goodness, faithfulness, gentleness, self-control.", ref: "Galatians 5:22–23" },
  { text: "For by grace you have been saved through faith. And this is not your own doing; it is the gift of God.", ref: "Ephesians 2:8" },
  { text: "So now faith, hope, and love abide, these three; but the greatest of these is love.", ref: "1 Corinthians 13:13" },
  { text: "But God shows his love for us in that while we were still sinners, Christ died for us.", ref: "Romans 5:8" },
  { text: "The Lord bless you and keep you; the Lord make his face shine on you and be gracious to you; the Lord turn his face toward you and give you peace.", ref: "Numbers 6:24–26" },
  { text: "This is the day that the Lord has made; let us rejoice and be glad in it.", ref: "Psalm 118:24" },
  { text: "Create in me a clean heart, O God, and renew a right spirit within me.", ref: "Psalm 51:10" },
  { text: "The heart of man plans his way, but the Lord establishes his steps.", ref: "Proverbs 16:9" },
  { text: "Do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God.", ref: "Philippians 4:6" },
  { text: "And the peace of God, which surpasses all understanding, will guard your hearts and your minds in Christ Jesus.", ref: "Philippians 4:7" },
  { text: "Delight yourself in the Lord, and he will give you the desires of your heart.", ref: "Psalm 37:4" },
  { text: "I have been crucified with Christ. It is no longer I who live, but Christ who lives in me.", ref: "Galatians 2:20" },
  { text: "Love is patient and kind; love does not envy or boast; it is not arrogant or rude.", ref: "1 Corinthians 13:4–5" },
  { text: "But seek first the kingdom of God and his righteousness, and all these things will be added to you.", ref: "Matthew 6:33" },
  { text: "The Lord your God is in your midst, a mighty one who will save; he will rejoice over you with gladness.", ref: "Zephaniah 3:17" },
  { text: "Cast your burden on the Lord, and he will sustain you; he will never permit the righteous to be moved.", ref: "Psalm 55:22" },
  { text: "He gives power to the faint, and to him who has no might he increases strength.", ref: "Isaiah 40:29" },
  { text: "For where two or three are gathered in my name, there am I among them.", ref: "Matthew 18:20" },
  { text: "Greater love has no one than this, that someone lay down his life for his friends.", ref: "John 15:13" },
  { text: "Your word is a lamp to my feet and a light to my path.", ref: "Psalm 119:105" },
  { text: "The steadfast love of the Lord never ceases; his mercies never come to an end; they are new every morning; great is your faithfulness.", ref: "Lamentations 3:22–23" },
  { text: "The Lord is my light and my salvation; whom shall I fear?", ref: "Psalm 27:1" },
  { text: "I lift up my eyes to the hills. From where does my help come? My help comes from the Lord, who made heaven and earth.", ref: "Psalm 121:1–2" },
  { text: "Give thanks to the Lord, for he is good, for his steadfast love endures forever.", ref: "Psalm 136:1" },
  { text: "As iron sharpens iron, so one person sharpens another.", ref: "Proverbs 27:17" },
  { text: "Let us not become weary in doing good, for at the proper time we will reap a harvest if we do not give up.", ref: "Galatians 6:9" },
  { text: "So whether you eat or drink or whatever you do, do it all for the glory of God.", ref: "1 Corinthians 10:31" },
  { text: "No, in all these things we are more than conquerors through him who loved us.", ref: "Romans 8:37" },
  { text: "Now to him who is able to do far more abundantly than all that we ask or think, according to the power at work within us.", ref: "Ephesians 3:20" },
  { text: "I press on toward the goal for the prize of the upward call of God in Christ Jesus.", ref: "Philippians 3:14" },
  { text: "And let us consider how to stir up one another to love and good works, not neglecting to meet together.", ref: "Hebrews 10:24–25" },
  { text: "Rejoice always, pray without ceasing, give thanks in all circumstances; for this is the will of God in Christ Jesus for you.", ref: "1 Thessalonians 5:16–18" },
  { text: "The Lord is near to all who call on him, to all who call on him in truth.", ref: "Psalm 145:18" },
  { text: "Be kind to one another, tenderhearted, forgiving one another, as God in Christ forgave you.", ref: "Ephesians 4:32" },
  { text: "For I am sure that neither death nor life, nor angels nor rulers, nor things present nor things to come will be able to separate us from the love of God in Christ Jesus our Lord.", ref: "Romans 8:38–39" },
  { text: "Set your minds on things that are above, not on things that are on earth.", ref: "Colossians 3:2" },
  { text: "And my God will supply every need of yours according to his riches in glory in Christ Jesus.", ref: "Philippians 4:19" },
  { text: "But they who wait for the Lord shall renew their strength; they shall mount up with wings like eagles; they shall run and not be weary; they shall walk and not faint.", ref: "Isaiah 40:31" },
  { text: "The name of the Lord is a strong tower; the righteous man runs into it and is safe.", ref: "Proverbs 18:10" },
  { text: "Be still, and know that I am God.", ref: "Psalm 46:10" },
  { text: "Draw near to God, and he will draw near to you.", ref: "James 4:8" },
  { text: "For the wages of sin is death, but the free gift of God is eternal life in Christ Jesus our Lord.", ref: "Romans 6:23" },
  { text: "I am the vine; you are the branches. Whoever abides in me and I in him, he it is that bears much fruit, for apart from me you can do nothing.", ref: "John 15:5" },
  { text: "The Lord is my strength and my shield; in him my heart trusts, and I am helped.", ref: "Psalm 28:7" },
  { text: "If my people who are called by my name humble themselves, and pray and seek my face and turn from their wicked ways, then I will hear from heaven.", ref: "2 Chronicles 7:14" },
  { text: "And whatever you do, in word or deed, do everything in the name of the Lord Jesus, giving thanks to God the Father through him.", ref: "Colossians 3:17" },
  { text: "For the Lord your God is a merciful God. He will not leave you or destroy you.", ref: "Deuteronomy 4:31" },
  { text: "Let your light shine before others, so that they may see your good works and give glory to your Father who is in heaven.", ref: "Matthew 5:16" },
  { text: "Commit your work to the Lord, and your plans will be established.", ref: "Proverbs 16:3" },
  { text: "The Lord is good, a stronghold in the day of trouble; he knows those who take refuge in him.", ref: "Nahum 1:7" },
  { text: "For in him we live and move and have our being.", ref: "Acts 17:28" },
];

// ── Daily verse ───────────────────────────────────────────────────────────────

function renderDailyVerse() {
  const dayIndex = Math.floor(Date.now() / 86_400_000) % DAILY_VERSES.length;
  const verse    = DAILY_VERSES[dayIndex];
  document.getElementById('dv-text').textContent = `"${verse.text}"`;
  document.getElementById('dv-ref').textContent  = `— ${verse.ref}`;
}

// ── Latest group note ─────────────────────────────────────────────────────────

function escHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function loadLatestGroupNote() {
  const el = document.getElementById('gn-content');

  if (!user) {
    el.innerHTML = `<p class="gn-empty">Sign in to see the latest notes from your study groups.</p>`;
    return;
  }

  const groups = user.groups || [];

  if (groups.length === 0) {
    el.innerHTML = `<p class="gn-empty">Join or create a study group to see shared notes here.</p>`;
    return;
  }

  el.innerHTML = `<div class="gn-loading"><div class="gn-spinner"></div>Loading group notes…</div>`;

  const allNotes = [];

  await Promise.all(groups.map(async groupId => {
    try {
      const resp = await fetch(`${API}/groups/${user.user_id}/${groupId}/notes`);
      if (!resp.ok) { console.warn('[dashboard] loadLatestGroupNote: fetch failed', groupId, resp.status); return; }
      const data = await resp.json();
      // data shape: { username: { note_id: note_data } }
      for (const [username, noteMap] of Object.entries(data)) {
        for (const [noteId, note] of Object.entries(noteMap)) {
          allNotes.push({ ...note, _username: username, _groupId: groupId, _noteId: noteId });
        }
      }
    } catch (err) { console.error('[dashboard] loadLatestGroupNote: fetch error', groupId, err); }
  }));

  if (allNotes.length === 0) {
    el.innerHTML = `<p class="gn-empty">No group notes yet — be the first to share one while reading!</p>`;
    return;
  }

  allNotes.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
  const note = allNotes[0];

  // Build verse reference
  let refStr = '';
  try {
    const [[bS, cS, vS], [bE, cE, vE]] = note.verses;
    refStr = (bS === bE && cS === cE && vS === vE)
      ? `${bS} ${cS}:${vS}`
      : `${bS} ${cS}:${vS} – ${bE} ${cE}:${vE}`;
  } catch (err) { console.warn('[dashboard] loadLatestGroupNote: verse ref malformed', err); }

  // Format date
  let timeStr = '';
  try {
    timeStr = new Date(note.timestamp).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  } catch (err) { console.warn('[dashboard] loadLatestGroupNote: timestamp malformed', err); }

  el.innerHTML = `
    <p class="gn-note-title">${escHtml(note.title || 'Untitled Note')}</p>
    <p class="gn-note-text">${escHtml(note.text)}</p>
    <div class="gn-meta">
      <span class="gn-author">@${escHtml(note._username)}</span>
      ${refStr ? `<span class="gn-dot"></span><span class="gn-ref">${escHtml(refStr)}</span>` : ''}
      ${timeStr ? `<span class="gn-time">${timeStr}</span>` : ''}
    </div>
  `;
}

// ── Nav account link ──────────────────────────────────────────────────────────

(function () {
  const label  = !user ? 'Sign In' : (user.username || 'Account');
  const href   = !user ? 'signin.html' : 'account.html';
  const nav    = document.getElementById('nav-account');
  const drawer = document.getElementById('drawer-account');
  if (nav)    { nav.textContent    = label; nav.href    = href; }
  if (drawer) { drawer.textContent = label; drawer.href = href; }
})();

// ── Boot ──────────────────────────────────────────────────────────────────────

renderDailyVerse();
loadLatestGroupNote();
