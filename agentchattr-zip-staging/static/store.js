/**
 * store.js -- Minimal reactive state for agentchattr
 *
 * Thin wrapper: get/set/watch. During the transition, feature modules
 * proxy their globals through here one feature at a time (starting
 * with Sessions in PR 2).
 *
 * Usage:
 *   Store.set('activeChannel', 'general');
 *   Store.get('activeChannel');  // 'general'
 *   Store.watch('activeChannel', (newVal, oldVal) => { ... });
 */

const Store = (() => {
    const _state = {};
    const _watchers = {};

    function get(key) {
        return _state[key];
    }

    function set(key, value) {
        const old = _state[key];
        if (old === value) return;
        _state[key] = value;
        const list = _watchers[key];
        if (list) {
            for (const fn of list) {
                try {
                    fn(value, old);
                } catch (e) {
                    console.error(`[Store] Error in watcher for "${key}":`, e);
                }
            }
        }
    }

    function watch(key, fn) {
        if (!_watchers[key]) _watchers[key] = [];
        _watchers[key].push(fn);
    }

    function unwatch(key, fn) {
        const list = _watchers[key];
        if (!list) return;
        const idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
    }

    return { get, set, watch, unwatch };
})();

// Make Store available globally during the transition period.
window.Store = Store;
