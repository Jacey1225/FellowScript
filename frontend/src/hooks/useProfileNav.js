import { useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { isProfileId, profilePath } from '../lib/profileId.js';

export { isProfileId, profilePath };

// Returns openProfile(id): navigates to the profile page, or returns false
// (does nothing) when the id is not a real user id.
export default function useProfileNav() {
  const navigate = useNavigate();
  return useCallback((id) => {
    const path = profilePath(id);
    if (!path) return false;
    navigate(path);
    return true;
  }, [navigate]);
}
