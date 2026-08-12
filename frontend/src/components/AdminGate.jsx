import React, { useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';

// Defense-in-depth only. The real enforcement boundary is the server-side
// `require_admin` dependency on every /monitoring/* endpoint (401
// unauthenticated, 403 authenticated-but-non-admin) -- this wrapper exists
// so a non-admin doesn't see a flash of broken/empty admin chrome, not to
// provide any actual security.
//
// There is no client-visible `is_admin` field on the user object, so this
// component only handles the trivial synchronous case: no session at all.
// The 401 (session expired mid-flight) and 403 (authenticated, not admin)
// cases are handled by each admin page's own first data fetch -- the fetch
// itself IS the gate, since it's the only place that can actually learn
// whether the caller is an admin. Both admin routes wrap themselves in this
// component independently and perform that fetch-driven check themselves;
// see AdminDetections.jsx / AdminDetectionDetail.jsx.
export default function AdminGate({ children }) {
  const { user } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    if (!user) navigate('/signin', { replace: true });
  }, [user, navigate]);

  if (!user) return null;
  return children;
}
