/*
    html/tests/dom-stub.js

    A minimal, hand-rolled DOM stand-in -- deliberately NOT a general
    DOM/CSS engine (no jsdom dependency; see DEVELOPER_REFERENCE.md's own "why not
    busted" reasoning on the Lua side for the same anti-dependency posture
    applied here). html/app.js's ENTIRE DOM surface is narrow enough to
    hand-implement exactly:

        document.getElementById('k9hud')
        document.querySelector('[data-xxx="yyy"]')   -- attribute-equals only
        document.addEventListener('DOMContentLoaded', fn)
        document.readyState
        el.classList.add/remove/toggle/contains
        el.style.width = '...'
        el.textContent (get/set)
        el.setAttribute/getAttribute
        el.innerHTML (app.js's contract is that this is NEVER written to --
            see the innerHTML trap below, which is this harness's actual
            proof mechanism for that claim, not just a grep)

    This file builds a DOM tree that mirrors html/index.html's real
    structure byte-for-byte (same data-stat-row/data-fill/data-value/
    data-status hooks, same starting classes) -- see buildK9HudDocument()
    below -- so a spec exercising app.js's init() against this stub is
    exercising the exact same element wiring the real page provides, not a
    simplified stand-in that could hide a real attribute-name mismatch.
*/
'use strict';

function makeClassList() {
    const set = new Set();
    return {
        add(c) { set.add(c); },
        remove(c) { set.delete(c); },
        toggle(c, force) {
            if (force === undefined) {
                if (set.has(c)) { set.delete(c); return false; }
                set.add(c);
                return true;
            }
            if (force) { set.add(c); return true; }
            set.delete(c);
            return false;
        },
        contains(c) { return set.has(c); },
        toArray() { return Array.from(set); },
    };
}

class Element {
    constructor(tagName, attrs) {
        this.tagName = tagName;
        this._attrs = Object.assign({}, attrs);
        this.classList = makeClassList();
        if (this._attrs.class) {
            for (const c of this._attrs.class.split(/\s+/).filter(Boolean)) {
                this.classList.add(c);
            }
        }
        this.style = {};
        this._textContent = '';
        this._innerHTMLWrites = [];
    }

    setAttribute(name, value) {
        this._attrs[name] = String(value);
    }

    getAttribute(name) {
        return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
    }

    /** Test-only inspection hook -- NOT part of any real DOM API -- so specs
     * can assert on exactly what classes are currently applied without
     * reaching into the private Set backing classList. */
    get classListArray() {
        return this.classList.toArray();
    }

    /** How many times innerHTML was ever written to this element -- the
     * XSS spec's actual assertion point (see xss_spec.js): app.js's own
     * header claims "never innerHTML" throughout; this is what proves that
     * claim rather than trusting it. */
    get innerHTMLWriteCount() {
        return this._innerHTMLWrites.length;
    }
}

Object.defineProperty(Element.prototype, 'textContent', {
    get() { return this._textContent; },
    // Real DOM coerces any assigned value to a string (WebIDL `DOMString?`
    // with null -> empty string) -- app.js assigns both numbers
    // (Math.round(pct) in applyStat) and strings (the fixed
    // 'Distracted'/'Clear' literals, and the network-sourced xpTier label)
    // here, so this stub mirrors that coercion rather than storing
    // whatever raw type was assigned, matching what a spec reading
    // `.textContent` back out would actually see in a browser.
    set(v) { this._textContent = v === null ? '' : String(v); },
});

// Trapped, not simply "unsupported" -- a real DOM element DOES have a
// writable innerHTML, so a stub that just omitted it (throwing
// "Cannot set property" as a TypeError on assignment) would still degrade
// to "app.js can't actually write it here," but for the wrong, accidental
// reason (no setter at all) rather than the right one (this harness is
// actively watching for the write and recording it for a real
// assertion). Recording (not throwing) also means a spec that DOES want to
// prove the code below never calls this at all can assert
// `.innerHTMLWriteCount === 0` directly and get a clear failure message,
// rather than the test blowing up with an opaque low-level TypeError if
// app.js is ever changed to write it.
Object.defineProperty(Element.prototype, 'innerHTML', {
    get() {
        return this._innerHTMLWrites.length > 0 ? this._innerHTMLWrites[this._innerHTMLWrites.length - 1] : '';
    },
    set(v) {
        this._innerHTMLWrites.push(v);
    },
});

const ATTR_SELECTOR_RE = /^\[([a-zA-Z0-9_-]+)="([^"]*)"\]$/;

class FakeDocument {
    constructor() {
        this._byId = new Map();
        this._all = [];
        this._listeners = {};
        this.readyState = 'complete'; // see sandbox.js for why this default is deliberate
    }

    _register(el, id) {
        this._all.push(el);
        if (id) this._byId.set(id, el);
        return el;
    }

    createElement(tagName, attrs) {
        return this._register(new Element(tagName, attrs));
    }

    getElementById(id) {
        return this._byId.get(id) || null;
    }

    /** Deliberately narrow: only supports the exact `[attr="value"]` shape
     * html/app.js's own init() ever calls this with -- see this file's
     * header. Anything else throws loudly (a spec author's mistake, not a
     * silent app.js failure) rather than silently returning null and
     * masking a real bug in the selector itself. */
    querySelector(selector) {
        const m = ATTR_SELECTOR_RE.exec(selector);
        if (!m) {
            throw new Error(`dom-stub: querySelector only supports [attr="value"] selectors, got: ${selector}`);
        }
        const [, attr, value] = m;
        for (const el of this._all) {
            if (el.getAttribute(attr) === value) return el;
        }
        return null;
    }

    addEventListener(type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    }

    removeEventListener(type, fn) {
        const list = this._listeners[type];
        if (!list) return;
        const idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
    }

    /** Test-only: fires every listener registered for `type` -- used to
     * drive the document.readyState === 'loading' -> DOMContentLoaded path
     * (see sandbox.js's `deferReady` option). Not a real DOM method. */
    _dispatch(type, evt) {
        const list = this._listeners[type] || [];
        for (const fn of list.slice()) fn(evt);
    }
}

/** One (row, fill, value) triple for a bar-stat row, matching
 * index.html's own markup for health/stamina/hunger/thirst/fatigue
 * exactly (same three data-* hooks, same starting `k9hud-row--hidden`
 * class on the wellbeing-extension row, per index.html's own comment on
 * why it starts pre-hidden). */
function addBarRow(doc, stat, startHidden) {
    const row = doc.createElement('div', { 'data-stat-row': stat, class: startHidden ? 'k9hud-row k9hud-row--hidden' : 'k9hud-row' });
    doc._register(row);
    const fill = doc.createElement('div', { 'data-fill': stat });
    doc._register(fill);
    const value = doc.createElement('span', { 'data-value': stat });
    value.textContent = '--';
    doc._register(value);
}

/** One (row, value) pair for a status-text row (distraction/xpTier) --
 * same starting-hidden posture as the bar rows, see index.html's own
 * comment on both. */
function addStatusRow(doc, stat) {
    const row = doc.createElement('div', { 'data-stat-row': stat, class: 'k9hud-row k9hud-row--hidden k9hud-row--status' });
    doc._register(row);
    const value = doc.createElement('span', { 'data-status': stat });
    value.textContent = '--';
    doc._register(value);
}

/**
 * The HANDLER CONDITION BADGE's own (row, label, value) triple -- mirrors
 * html/index.html's real `#k9partner-badge` markup byte-for-byte (same
 * `id`/`data-partner="label"`/`data-partner="value"` hooks, same starting
 * `hidden` class -- see that file's own comment on why this is a SEPARATE
 * element from `#k9hud`, not one more row inside it).
 */
function addPartnerBadge(doc) {
    const row = doc.createElement('div', { id: 'k9partner-badge', class: 'k9partner-badge hidden', 'aria-hidden': 'true' });
    doc._register(row, 'k9partner-badge');
    const label = doc.createElement('span', { 'data-partner': 'label' });
    label.textContent = 'K9 Partner';
    doc._register(label);
    const value = doc.createElement('span', { 'data-partner': 'value' });
    value.textContent = '--';
    doc._register(value);
}

/**
 * The K9 ONBOARDING HINT's own (row, title, body, dismiss) quadruple --
 * mirrors html/index.html's real `#k9onboarding-hint` markup byte-for-byte
 * (same `id`/`data-onboarding="title"`/`data-onboarding="body"`/
 * `data-onboarding="dismiss"` hooks, same starting `hidden` class -- see
 * that file's own comment on why this is a THIRD, separate element from
 * `#k9hud`/`#k9partner-badge`, not one more row inside either).
 */
function addOnboardingHint(doc) {
    const row = doc.createElement('div', { id: 'k9onboarding-hint', class: 'k9onboarding-hint hidden', 'aria-hidden': 'true' });
    doc._register(row, 'k9onboarding-hint');
    const title = doc.createElement('span', { 'data-onboarding': 'title' });
    title.textContent = 'K9 Command Tablet';
    doc._register(title);
    const body = doc.createElement('span', { 'data-onboarding': 'body' });
    body.textContent = '--';
    doc._register(body);
    const dismiss = doc.createElement('span', { 'data-onboarding': 'dismiss' });
    dismiss.textContent = '--';
    doc._register(dismiss);
}

/**
 * Builds a FakeDocument whose element graph mirrors html/index.html's real
 * #k9hud markup byte-for-byte on every attribute/class app.js's init()
 * actually reads -- see this file's header. Returns the FakeDocument
 * itself (pass as the vm sandbox's `document`).
 * @returns {FakeDocument}
 */
function buildK9HudDocument() {
    const doc = new FakeDocument();

    const root = doc.createElement('div', { id: 'k9hud', class: 'k9hud hidden', 'aria-hidden': 'true' });
    doc._register(root, 'k9hud');

    for (const stat of ['health', 'stamina', 'hunger', 'thirst']) {
        addBarRow(doc, stat, false);
    }
    addBarRow(doc, 'fatigue', true);
    addStatusRow(doc, 'xpTier');
    addPartnerBadge(doc);
    addOnboardingHint(doc);

    return doc;
}

module.exports = { Element, FakeDocument, buildK9HudDocument };
