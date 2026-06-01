import { useState, useCallback, useRef, useEffect } from 'react';
import { buildChapterHTML, extractVerseNums } from '../utils.js';

// Module-level cache — survives component unmount/remount within the same session
let _cachedBible = null;

export function useBible() {
  const [bible,      setBible]      = useState(_cachedBible);
  const [loading,    setLoading]    = useState(!_cachedBible);
  const [loadError,  setLoadError]  = useState(false);
  const [curBook,    setCurBook]    = useState(null);
  const [curChapter, setCurChapter] = useState(null);
  const [chapterHTML, setChapterHTML] = useState('');
  const [verseNums,   setVerseNums]   = useState([]);
  const [books,       setBooks]       = useState(_cachedBible ? Object.keys(_cachedBible) : []);
  const onRendered = useRef(() => {});

  // Persist position so it survives navigation away and back
  useEffect(() => {
    if (!curBook || !curChapter) return;
    try {
      localStorage.setItem('fs_bible_pos', JSON.stringify({ book: curBook, chapter: curChapter }));
    } catch {}
  }, [curBook, curChapter]);

  const setChapterRenderedCallback = useCallback(fn => { onRendered.current = fn; }, []);

  const loadBible = useCallback(async () => {
    if (_cachedBible) {
      setBible(_cachedBible);
      setBooks(Object.keys(_cachedBible));
      setLoading(false);
      return _cachedBible;
    }
    try {
      const res = await fetch('/data/bible.json');
      if (!res.ok) throw new Error(res.status);
      const data = await res.json();
      _cachedBible = data;
      setBible(data);
      setBooks(Object.keys(data));
      setLoading(false);
      return data;
    } catch {
      setLoadError(true);
      setLoading(false);
      return null;
    }
  }, []);

  const getChapters = useCallback((b, bibleData) => {
    const src = bibleData || bible;
    if (!src || !src[b]) return [];
    const entries = src[b];
    return entries.length === 1 ? entries : entries.slice(1);
  }, [bible]);

  const setBook = useCallback((book) => {
    setCurBook(book);
    setCurChapter(null);
    setChapterHTML('');
    setVerseNums([]);
  }, []);

  const setChapter = useCallback((chNum, book, bibleData) => {
    const b   = book || curBook;
    const src = bibleData || bible;
    if (!b || !src) return;
    const chapters = getChapters(b, src);
    if (chNum < 1 || chNum > chapters.length) return;
    const chStr = chapters[chNum - 1];
    setCurChapter(chNum);
    setChapterHTML(buildChapterHTML(chStr));
    setVerseNums(extractVerseNums(chStr));
    setTimeout(() => onRendered.current(), 0);
  }, [bible, curBook, getChapters]);

  const chapterCount = useCallback((book, bibleData) => {
    return getChapters(book || curBook, bibleData).length;
  }, [getChapters, curBook]);

  const verseCount = useCallback((book, chapter) => {
    const chapters = getChapters(book, null);
    if (!chapters.length || chapter < 1 || chapter > chapters.length) return 0;
    return extractVerseNums(chapters[chapter - 1]).length;
  }, [getChapters]);

  const getPreamble = useCallback((book, bibleData) => {
    const src = bibleData || bible;
    if (!src || !book) return '';
    const isSingle = src[book]?.length === 1;
    return isSingle ? '' : (src[book]?.[0] || '').replace('HEAD::', '').trim();
  }, [bible]);

  return {
    bible, loading, loadError, curBook, curChapter,
    chapterHTML, verseNums, books,
    loadBible, setBook, setChapter, getChapters, chapterCount, verseCount, getPreamble,
    setChapterRenderedCallback,
  };
}
