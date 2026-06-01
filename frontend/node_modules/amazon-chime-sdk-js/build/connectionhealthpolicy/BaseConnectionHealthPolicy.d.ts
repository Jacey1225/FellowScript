import ConnectionHealthData from './ConnectionHealthData';
import ConnectionHealthPolicy from './ConnectionHealthPolicy';
import ConnectionHealthPolicyConfiguration from './ConnectionHealthPolicyConfiguration';
export default class BaseConnectionHealthPolicy implements ConnectionHealthPolicy {
    protected currentData: ConnectionHealthData;
    protected minHealth: number;
    protected maxHealth: number;
    protected currentHealth: number;
    readonly name?: string;
    constructor(configuration: ConnectionHealthPolicyConfiguration, data: ConnectionHealthData, name?: string);
    minimumHealth(): number;
    maximumHealth(): number;
    health(): number;
    update(connectionHealthData: ConnectionHealthData): void;
    getConnectionHealthData(): ConnectionHealthData;
    healthy(): boolean;
    healthIfChanged(): number | null;
}
