/**
 * core.js -- EventHub for agentchattr
 *
 * Tiny pub/sub hub. WebSocket events are emitted here so modules can
 * subscribe without touching the legacy switch statement in chat.js.
 *
 * Usage:
 *   Hub.on('session', (data) => { ... });
 *   Hub.emit('session', { action: 'create', data: session });
 *   Hub.off('session', handler);
 */

const Hub = (() => {
    const _listeners = {};

    function on(type, fn) {
        if (!_listeners[type]) _listeners[type] = [];
        _listeners[type].push(fn);
    }

    function off(type, fn) {
        const list = _listeners[type];
        if (!list) return;
        const idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
    }

    function emit(type, data) {
        const list = _listeners[type];
        if (!list) return;
        for (const fn of list) {
            try {
                fn(data);
            } catch (e) {
                console.error(`[Hub] Error in listener for "${type}":`, e);
            }
        }
    }

    return { on, off, emit };
})();

// Make Hub available globally during the transition period.
// Once all modules use ES imports, this can be removed.
window.Hub = Hub;
