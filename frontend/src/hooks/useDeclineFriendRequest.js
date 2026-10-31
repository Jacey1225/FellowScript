// Task 20261030-profile-everywhere: Decline for the Account "Friend Requests"
// rows. The row leaves the list only after the server answers 204 (the route
// answers the same whether or not a request existed). On any failure the
// request stays visible and a warm error is shown (throw-not-fabricate).
import { useCallback, useState } from 'react';
import { message } from 'antd';
import { declineFriendRequest, DECLINE_FAILURE } from '../lib/profileApi.js';

const RATE_COPY = 'Slow down a little and try again in a moment.';

export function useDeclineFriendRequest(userId, setRequests) {
  const [declining, setDeclining] = useState({});

  const decline = useCallback(async (senderId) => {
    if (!userId || declining[senderId]) return false;
    setDeclining((prev) => ({ ...prev, [senderId]: true }));
    try {
      await declineFriendRequest(userId, senderId);
      setRequests((prev) => prev.filter((r) => r.uid !== senderId));
      return true;
    } catch (err) {
      message.error(err?.status === 429 ? RATE_COPY : DECLINE_FAILURE);
      return false;
    } finally {
      setDeclining((prev) => ({ ...prev, [senderId]: false }));
    }
  }, [userId, declining, setRequests]);

  return { decline, declining };
}
