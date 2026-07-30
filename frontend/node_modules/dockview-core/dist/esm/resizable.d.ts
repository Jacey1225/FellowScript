import { CompositeDisposable } from './lifecycle';
export declare abstract class Resizable extends CompositeDisposable {
    private readonly _element;
    private _disableResizing;
    private _lastWidth;
    private _lastHeight;
    get element(): HTMLElement;
    get disableResizing(): boolean;
    set disableResizing(value: boolean);
    constructor(parentElement: HTMLElement, disableResizing?: boolean);
    abstract layout(width: number, height: number): void;
}
