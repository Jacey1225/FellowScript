// Community-themed Scripture for the Home hero descent (task
// 20261022-hands-scroll-grain-gradient). World English Bible (public domain), the
// translation the app already ships. Text is copied verbatim from data/bible.json;
// verseDescent.test.js re-checks every string against that file, so a drifted or
// invented verse fails the suite. Never edit a string here from memory.
export const COMMUNITY_VERSES = [
  {
    ref: 'Hebrews 10:24-25',
    text: 'Let us consider how to provoke one another to love and good works, not forsaking our own assembling together, as the custom of some is, but exhorting one another; and so much the more, as you see the Day approaching.',
  },
  {
    ref: 'Proverbs 27:17',
    text: 'Iron sharpens iron; so a man sharpens his friend’s countenance.',
  },
  {
    ref: 'Ecclesiastes 4:9-12',
    text: 'Two are better than one, because they have a good reward for their labor. For if they fall, the one will lift up his fellow; but woe to him who is alone when he falls, and doesn’t have another to lift him up. Again, if two lie together, then they have warmth; but how can one keep warm alone? If a man prevails against one who is alone, two shall withstand him; and a threefold cord is not quickly broken.',
  },
  {
    ref: 'Acts 2:44-45',
    text: 'All who believed were together, and had all things in common. They sold their possessions and goods, and distributed them to all, according as anyone had need.',
  },
  {
    ref: '1 Thessalonians 5:11',
    text: 'Therefore exhort one another, and build each other up, even as you also do.',
  },
];

// Throw rather than render a blank or partial verse card.
for (const v of COMMUNITY_VERSES) {
  if (!v || typeof v.ref !== 'string' || !v.ref || typeof v.text !== 'string' || !v.text.trim()) {
    throw new Error('communityVerses: every verse needs a reference and WEB text');
  }
}
