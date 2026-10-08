import { useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { setMfaRequiredFlag } from '../lib/adminMfa.js';

// Returns a function that ends the admin's session and sends them to sign-in
// with the "2FA required" notice. Shared by every admin surface so the
// mfa_required 403 is handled one way everywhere.
export function useAdminMfaRequired() {
  const signOut = useAuth()?.signOut;
  const navigate = useNavigate();
  return useCallback(() => {
    setMfaRequiredFlag();
    if (signOut) signOut();
    navigate('/signin', { replace: true, state: { mfaRequired: true } });
  }, [signOut, navigate]);
}
