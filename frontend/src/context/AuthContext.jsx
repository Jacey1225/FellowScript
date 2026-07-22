import React, { createContext, useContext, useState, useCallback } from 'react';
import { API } from '../config.js';

const AuthContext = createContext(null);

function getStoredUser() {
  try {
    const s = JSON.parse(sessionStorage.getItem('user') || 'null');
    if (s) return s;
    const l = JSON.parse(localStorage.getItem('fs_user') || 'null');
    if (l) { sessionStorage.setItem('user', JSON.stringify(l)); return l; }
  } catch {}
  return null;
}

export function AuthProvider({ children }) {
  const [user, setUser] = useState(() => getStoredUser());

  const signIn = useCallback((userData) => {
    sessionStorage.setItem('user', JSON.stringify(userData));
    localStorage.setItem('fs_user', JSON.stringify(userData));
    setUser(userData);
  }, []);

  const signOut = useCallback(() => {
    // End the server-side session too — the cookie is httponly, so this is
    // the only way to actually invalidate it (clearing local state alone
    // would leave the session live and reusable).
    fetch(`${API}/logout`, { method: 'POST', credentials: 'include' }).catch(() => {});
    sessionStorage.removeItem('user');
    localStorage.removeItem('fs_user');
    localStorage.removeItem('last_page');
    setUser(null);
  }, []);

  const updateUser = useCallback((patch) => {
    setUser(prev => {
      const updated = { ...prev, ...patch };
      sessionStorage.setItem('user', JSON.stringify(updated));
      localStorage.setItem('fs_user', JSON.stringify(updated));
      return updated;
    });
  }, []);

  return (
    <AuthContext.Provider value={{ user, signIn, signOut, updateUser }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
