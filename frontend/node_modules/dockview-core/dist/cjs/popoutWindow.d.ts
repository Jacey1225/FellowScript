import { CspNonceProvider } from './dom';
import { CompositeDisposable } from './lifecycle';
import { Box } from './types';
export type PopoutWindowOptions = {
    url: string;
    onDidOpen?: (event: {
        id: string;
        window: Window;
    }) => void;
    onWillClose?: (event: {
        id: string;
        window: Window;
    }) => void;
    nonce?: CspNonceProvider;
} & Box;
/**
 * Reject popout URLs that aren't same-origin http(s). Blocks `javascript:`,
 * `data:`, `blob:`, `vbscript:`, and cross-origin URLs that would otherwise
 * execute in a context the browser still associates with the opener via
 * `window.opener`.
 */
export declare function assertSameOriginPopoutUrl(url: string): void;
export declare class PopoutWindow extends CompositeDisposable {
    private readonly target;
    private readonly className;
    private readonly options;
    private readonly _onWillClose;
    readonly onWillClose: import("./events").Event<void>;
    private readonly _onDidClose;
    readonly onDidClose: import("./events").Event<void>;
    private _window;
    get window(): Window | null;
    constructor(target: string, className: string, options: PopoutWindowOptions);
    dimensions(): Box | null;
    close(): void;
    open(): Promise<HTMLElement | null>;
    private createPopoutWindowContainer;
}
