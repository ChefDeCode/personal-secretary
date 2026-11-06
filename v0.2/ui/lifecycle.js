// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
/* UI-only lifecycle. Hiding a native transparent WebView does not hide its document.
   The host sends pageVisibility; visual work stops, durable actions stay in the host. */
(function (root) {
  'use strict';
  root.SecretaryLife = function (options) {
    options = options || {};
    var hostVisible = options.visible !== false, active = false, serial = 0;
    var tasks = new Map(), pending = new Map(), changes = [], maxPending = options.maxPending || 128;
    var timer = root.setTimeout.bind(root), cancel = root.clearTimeout.bind(root);
    var raf = root.requestAnimationFrame.bind(root), caf = root.cancelAnimationFrame.bind(root);
    function visible() { return hostVisible && !document.hidden; }
    function schedule(id, task) {
      if (!active) return;
      if (task.frame) task.handle = raf(function (now) { tasks.delete(id); if (active) task.fn(now); });
      else task.handle = timer(function () { tasks.delete(id); if (active) task.fn(); }, Math.max(0, task.due - Date.now()));
    }
    function clear(id) {
      var task = tasks.get(id); if (!task) return;
      (task.frame ? caf : cancel)(task.handle); tasks.delete(id);
    }
    function sync() {
      var next = visible(); if (next === active) return;
      active = next;
      document.documentElement.setAttribute('data-page-active', active ? 'true' : 'false');
      if (!active) tasks.forEach(function (task) { (task.frame ? caf : cancel)(task.handle); });
      else {
        tasks.forEach(function (task, id) { schedule(id, task); });
        var work = Array.from(pending.values()); pending.clear();
        work.forEach(function (entry) { entry.fn(entry.data); });
      }
      changes.slice().forEach(function (fn) { fn(active); });
    }
    document.addEventListener('visibilitychange', sync);
    document.documentElement.setAttribute('data-page-active', 'false');
    sync();
    return {
      visible: function () { return active; },
      setVisible: function (value) { hostVisible = !!value; sync(); },
      onChange: function (fn) { changes.push(fn); },
      timeout: function (fn, ms) { var id = ++serial, task = { fn: fn, due: Date.now() + (ms || 0), frame: false }; tasks.set(id, task); schedule(id, task); return id; },
      clearTimeout: clear,
      frame: function (fn) { var id = ++serial, task = { fn: fn, frame: true }; tasks.set(id, task); schedule(id, task); return id; },
      cancelFrame: clear,
      accept: function (data, fn) {
        if (active) { fn(data); return; }
        // Snapshots replace earlier snapshots. Item updates keep one latest version per ID.
        // Items remain persisted by the host; this is a presentation cache, never the task queue.
        var key = data.type + (data.type === 'item' && data.item ? ':' + data.item.id : data.id ? ':' + data.id : '');
        if (data.type === 'init') pending.clear();
        pending.delete(key); pending.set(key, { data: data, fn: fn });
        // A long-hidden page must not retain an unbounded second chat archive.
        // pageResumed asks the host for an authoritative snapshot on every resume.
        while (pending.size > maxPending) pending.delete(pending.keys().next().value);
      },
      pendingCount: function () { return pending.size; }
    };
  };
})(window);
