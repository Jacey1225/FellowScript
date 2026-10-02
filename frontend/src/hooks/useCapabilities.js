import { useContext } from 'react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

// Outside a provider (unit tests, isolated components) every feature is off
// and terms are treated as current: the fail-closed default.
export function useCapabilities() {
  return useContext(CapabilitiesContext);
}
