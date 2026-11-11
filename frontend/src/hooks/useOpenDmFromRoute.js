// Task 20261030-user-profiles: the profile page's Message button navigates to
// /reader with location.state.openDm = { id, name, photoUrl }. Once contacts
// have loaded, open that DM once and clear the state so a refresh doesn't
// reopen it.
import { useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';

export function useOpenDmFromRoute({ loaded, onLoad, friends, onOpen }) {
  const location = useLocation();
  const navigate = useNavigate();
  const dm = location.state?.openDm;
  useEffect(() => {
    if (!dm?.id) return;
    if (!loaded) { onLoad(); return; }
    const known = (friends || []).find((f) => f.id === dm.id);
    navigate(location.pathname + location.search, { replace: true, state: null });
    onOpen(known || { id: dm.id, name: dm.name, type: 'friend', toUsers: [dm.id], preview: '', photoUrl: dm.photoUrl || null });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dm?.id, loaded]);
}
