/**
 * One floating surface at a time: a menu, the note picker, the teach-a-fix form, the
 * date jump. Positioned in viewport coordinates under (or above) an anchor, clamped to
 * the window, and dismissed by Escape, a click outside, a scroll or a resize.
 *
 * The surface is appended to <body>, so no transformed ancestor (the page entrance
 * animation) can shift a `position: fixed` box.
 */

export interface FloatingOptions {
  content: HTMLElement;
  /** The element or rectangle to sit next to. */
  anchor: HTMLElement | DOMRect;
  /** Where the surface prefers to open. `auto` opens below and flips when there is no room. */
  placement?: 'below' | 'above' | 'auto';
  /** Which edge of the anchor the surface lines up with. */
  align?: 'start' | 'end';
  /** Gap to the anchor in px. */
  gap?: number;
  /** Extra class on the surface. */
  className?: string;
  /** Accessible name. */
  label: string;
  role?: 'dialog' | 'menu' | 'listbox';
  onClose?: () => void;
  /** Receives focus when the surface closes while focus is inside it. */
  returnFocus?: HTMLElement | null;
}

export interface FloatingHandle {
  element: HTMLElement;
  close: () => void;
}

const MARGIN = 8;
let current: FloatingHandle | null = null;

export function closeFloating(): void {
  current?.close();
}

export function floatingIsOpen(): boolean {
  return current !== null;
}

export function openFloating(options: FloatingOptions): FloatingHandle {
  closeFloating();

  const { content, anchor, placement = 'auto', align = 'start', gap = 6, className, label, role = 'dialog' } = options;
  const surface = document.createElement('div');
  surface.className = `floating${className ? ` ${className}` : ''}`;
  surface.setAttribute('role', role);
  surface.setAttribute('aria-label', label);
  surface.append(content);
  surface.style.visibility = 'hidden';
  document.body.append(surface);

  const rect = anchor instanceof HTMLElement ? anchor.getBoundingClientRect() : anchor;
  const width = surface.offsetWidth;
  const height = surface.offsetHeight;
  const viewportW = window.innerWidth;
  const viewportH = window.innerHeight;

  const room = { below: viewportH - rect.bottom - gap - MARGIN, above: rect.top - gap - MARGIN };
  const useAbove = placement === 'above'
    ? room.above >= height || room.above > room.below
    : placement === 'auto' && room.below < height && room.above > room.below;
  const top = useAbove ? Math.max(MARGIN, rect.top - gap - height) : rect.bottom + gap;
  let left = align === 'end' ? rect.right - width : rect.left;
  left = Math.min(Math.max(MARGIN, left), Math.max(MARGIN, viewportW - width - MARGIN));
  surface.style.left = `${Math.round(left)}px`;
  surface.style.top = `${Math.round(top)}px`;
  surface.style.maxHeight = `${Math.max(120, useAbove ? room.above : room.below)}px`;
  surface.dataset.placement = useAbove ? 'above' : 'below';
  surface.style.visibility = '';

  let closed = false;
  const onMouseDown = (event: MouseEvent): void => {
    const target = event.target as Node;
    if (surface.contains(target)) return;
    // A click on the anchor toggles it: the anchor's own handler closes, so do not
    // close here first and let it reopen.
    if (anchor instanceof HTMLElement && anchor.contains(target)) return;
    close();
  };
  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    event.stopPropagation();
    close();
  };
  const onScroll = (event: Event): void => {
    if (event.target instanceof Node && surface.contains(event.target)) return;
    close();
  };
  document.addEventListener('mousedown', onMouseDown, true);
  document.addEventListener('keydown', onKeyDown, true);
  document.addEventListener('scroll', onScroll, true);
  window.addEventListener('resize', closeFloating);

  function close(): void {
    if (closed) return;
    closed = true;
    document.removeEventListener('mousedown', onMouseDown, true);
    document.removeEventListener('keydown', onKeyDown, true);
    document.removeEventListener('scroll', onScroll, true);
    window.removeEventListener('resize', closeFloating);
    const hadFocus = surface.contains(document.activeElement);
    surface.remove();
    if (current === handle) current = null;
    if (hadFocus && options.returnFocus?.isConnected) options.returnFocus.focus();
    options.onClose?.();
  }

  const handle: FloatingHandle = { element: surface, close };
  current = handle;
  return handle;
}
