/*
 * Shell bridge shim.
 *
 * The page calls Shell.post(op, payload) and never learns which platform it
 * runs on. Transport order: Android JavascriptInterface, iOS message handler,
 * plain browser. See ../../BRIDGE.md for the contract.
 */
(function () {
  "use strict";

  var VERSION = 1;
  var DEFAULT_TIMEOUT = 30000;
  var AD_TIMEOUT = 90000;

  var pending = new Map();
  var seq = 0;

  function androidTransport() {
    var n = window.__shellNative;
    if (n && typeof n.post === "function") return function (s) { n.post(s); };
    return null;
  }

  function iosTransport() {
    var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.shell;
    if (h && typeof h.postMessage === "function") return function (s) { h.postMessage(s); };
    return null;
  }

  var transport = androidTransport() || iosTransport();

  function platform() {
    if (window.__shellNative) return "android";
    if (iosTransport()) return "ios";
    return "web";
  }

  function settle(id, ok, data) {
    var p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    clearTimeout(p.timer);
    p.resolve({ ok: ok, data: data || {} });
  }

  /* Called from native. Kept as a property of window so both webviews can
     reach it; unknown ids are ignored instead of throwing. */
  window.__shell = {
    resolve: function (id, ok, data) { settle(id, !!ok, data); },
    event: function (name, data) {
      var list = listeners[name] || [];
      for (var i = 0; i < list.length; i++) {
        try { list[i](data || {}); } catch (e) { /* a listener never breaks the bridge */ }
      }
    }
  };

  var listeners = {};

  /* Screen awake, browser side. The Screen Wake Lock API exists in Chrome, but
     not in the Android WebView, so inside an APK the request always goes to the
     host, which holds the window flag. A browser drops the lock whenever the
     page is hidden; a page that wants to stay lit therefore asks again on the
     way back. */
  var awake = false;
  var sentinel = null;

  function wakeLock(on) {
    awake = !!on;
    var wl = navigator.wakeLock;
    if (!wl || !wl.request) {
      return { ok: true, data: { on: awake, mode: "none" } };
    }
    if (awake) {
      if (!sentinel) {
        wl.request("screen").then(function (s) {
          sentinel = s;
          s.addEventListener("release", function () { sentinel = null; });
        }).catch(function () { /* hidden tab or a denied request: stay quiet */ });
      }
    } else if (sentinel) {
      var s = sentinel;
      sentinel = null;
      try { s.release(); } catch (e) { /* already released */ }
    }
    return { ok: true, data: { on: awake, mode: "wakeLock" } };
  }

  document.addEventListener("visibilitychange", function () {
    if (awake && !sentinel && document.visibilityState === "visible") wakeLock(true);
  });

  /* Full screen. The Android WebView has no Fullscreen API for elements -- the
     host hides the system bars instead -- so the request goes to the platform
     and only a plain browser is served by requestFullscreen here. */
  function fullscreen(on) {
    var el = document.documentElement;
    if (!el || !el.requestFullscreen) {
      return { ok: true, data: { on: on, mode: "none" } };
    }
    if (on) {
      var p = el.requestFullscreen();
      if (p && p.catch) p.catch(function () { /* needs a user gesture */ });
    } else if (document.fullscreenElement && document.exitFullscreen) {
      var q = document.exitFullscreen();
      if (q && q.catch) q.catch(function () {});
    }
    return { ok: true, data: { on: on, mode: "element" } };
  }

  /* Back gesture, browser side. A browser tab cannot cancel its own back
     gesture, but it can survive one: while the page wants the gesture we keep
     one history entry of our own on top of it, so a back press pops that entry
     instead of leaving the page. The entry is pushed again straight away and
     the "back" event fires, which is exactly what the native capture mode
     does. "pass" drops the guard, and the next gesture leaves. */
  var backMode = "pass";

  function armBackGuard() {
    try {
      if (!history.state || history.state.__shellBack !== 1) {
        history.pushState({ __shellBack: 1 }, "", location.href);
      }
    } catch (e) { /* a sandboxed frame may refuse; the page still works */ }
  }

  function browserBack(mode) {
    if (mode !== "capture" && mode !== "block") mode = "pass";
    backMode = mode;
    if (backMode !== "pass") armBackGuard();
    return { ok: true, data: { mode: backMode } };
  }

  window.addEventListener("popstate", function () {
    if (backMode === "pass") return;
    armBackGuard();
    var list = listeners["back"] || [];
    for (var i = 0; i < list.length; i++) {
      try { list[i]({ mode: backMode, press: 1 }); } catch (e) { /* never breaks the bridge */ }
    }
  });

  /* Scheduling, browser side. A tab is not a scheduler: it cannot survive a
     reload or a closed browser, so nothing here pretends to hold a time. The
     answer is an honest "none", and a page that needs the promise must run
     inside the app or ask the server to remind it. */
  function browserSchedule(op, payload) {
    if (op === "schedule.state") {
      return { ok: true, data: {
        native: false, exact: false, alarmsAllowed: false, alarmClock: false,
        permission: notifyPermission()
      } };
    }
    if (op === "schedule.list") return { ok: true, data: { items: [] } };
    if (op === "schedule.cancel" || op === "notify.cancel") return { ok: true, data: {} };
    return { ok: true, data: {
      mode: "none", exact: false, alarmClock: false,
      kind: payload.kind === "alarm" ? "alarm" : "reminder"
    } };
  }

  /* Delivery, browser side. The Notification API covers the "show it now"
     case and nothing else: it needs the user's permission, it only renders
     while the browser lives, and on a phone browser it usually needs a service
     worker. That limit is reported, not hidden. */
  var openNotifications = {};

  function notifySupport() {
    return typeof window.Notification === "function";
  }

  function notifyPermission() {
    if (!notifySupport()) return "unsupported";
    if (Notification.permission === "default") return "prompt";
    return Notification.permission;
  }

  function browserNotify(op, payload) {
    if (op === "notify.permission") {
      return { ok: true, data: { state: notifyPermission() } };
    }
    if (op === "notify.dismiss") {
      var tag = String(payload.tag || payload.id || "");
      var n = openNotifications[tag];
      if (n) {
        try { n.close(); } catch (e) { /* already gone */ }
        delete openNotifications[tag];
      }
      return { ok: true, data: {} };
    }
    if (op !== "notify.show") return { ok: false, data: { error: "E_NOT_IMPLEMENTED" } };

    if (!notifySupport()) return { ok: false, data: { error: "E_NOT_IMPLEMENTED" } };
    if (Notification.permission !== "granted") return { ok: false, data: { error: "E_DENIED" } };

    var title = payload.title || "";
    var body = payload.body || "";
    if (!title && !body) return { ok: false, data: { error: "E_BAD_REQUEST" } };
    var tag = String(payload.tag || payload.id || "");
    var kind = payload.kind === "alarm" ? "alarm" : "reminder";
    try {
      var note = new Notification(title || (kind === "alarm" ? "Alarm" : "Reminder"), {
        body: body, tag: tag || undefined
      });
      if (tag) {
        openNotifications[tag] = note;
        note.addEventListener("close", function () { delete openNotifications[tag]; });
      }
    } catch (e) {
      /* A mobile browser without a service worker throws here. */
      return { ok: false, data: { error: "E_NOT_IMPLEMENTED" } };
    }
    return { ok: true, data: { mode: "web", kind: kind } };
  }

  function browserFallback(op, payload) {
    if (op === "back.mode") return browserBack(payload.mode);
    if (op === "device.info") {
      return { ok: true, data: { platform: "web", osVersion: "", appVersion: "", ops: [] } };
    }
    if (op === "haptics.impact") {
      if (navigator.vibrate) navigator.vibrate(payload.style === "heavy" ? 30 : 12);
      return { ok: true, data: {} };
    }
    if (op === "share") {
      if (navigator.share) {
        navigator.share({ text: payload.text || "", url: payload.url }).catch(function () {});
        return { ok: true, data: {} };
      }
      return { ok: false, data: { error: "E_NOT_IMPLEMENTED" } };
    }
    if (op === "openExternal") {
      window.open(payload.url, "_blank", "noopener");
      return { ok: true, data: {} };
    }
    if (op === "screen.keepAwake") {
      return wakeLock(payload.on !== false);
    }
    if (op === "screen.fullscreen") {
      return fullscreen(payload.on !== false);
    }
    if (op.indexOf("schedule.") === 0) return browserSchedule(op, payload);
    /* Deprecated aliases from before the split. */
    if (op === "notify.schedule" || op === "notify.cancel") {
      return browserSchedule(op, payload);
    }
    if (op.indexOf("notify.") === 0) return browserNotify(op, payload);
    if (op.indexOf("push.") === 0) {
      /* Push needs a build that carries a sender and a server that stores the
         device. A tab has neither, and pretending would be worse than saying
         no. */
      return { ok: false, data: { error: "E_NOT_IMPLEMENTED" } };
    }
    /* No SDK here, but the page still gets a truthful cache snapshot and a
       lazy show that reports "no fill" instead of hanging. */
    if (op === "ads.state") {
      return { ok: true, data: { interstitial: "none", rewarded: "none", banner: "none" } };
    }
    if (op === "ads.banner.show" || op === "ads.banner.hide") {
      return { ok: true, data: { shown: false } };
    }
    if (payload.policy === "lazy" && op.indexOf("ads.") === 0) {
      return { ok: true, data: { shown: false, reason: "no_fill" } };
    }
    return { ok: false, data: { error: "E_NOT_IMPLEMENTED" } };
  }

  /* A full-screen ad may only be asked for while the page is actually on
     screen: an interstitial that appears after the user pressed Home is a
     policy violation, and Google counts them. The host refuses these too;
     this is the earlier of the two checks. Banners are inline in the layout and
     are not gated: they cannot appear over another app. */
  var SHOWS_BACKGROUND = { "ads.interstitial.show": 1, "ads.rewarded.show": 1 };

  function post(op, payload) {
    payload = payload || {};
    var timeout = op.indexOf("ads.") === 0 ? AD_TIMEOUT : DEFAULT_TIMEOUT;

    return new Promise(function (resolve) {
      if (SHOWS_BACKGROUND[op] === 1 && document.visibilityState !== "visible") {
        resolve({ ok: true, data: { shown: false, reason: "background" } });
        return;
      }
      if (!transport) {
        var r = browserFallback(op, payload);
        resolve(r);
        return;
      }
      var id = (++seq).toString(36) + "-" + Date.now().toString(36);
      var timer = setTimeout(function () {
        settle(id, false, { error: "E_TIMEOUT" });
      }, timeout);
      pending.set(id, { resolve: resolve, timer: timer });
      try {
        transport(JSON.stringify({ v: VERSION, op: op, id: id, payload: payload }));
      } catch (e) {
        settle(id, false, { error: "E_INTERNAL", message: String(e) });
      }
    });
  }

  window.Shell = {
    version: VERSION,
    platform: platform(),
    post: post,
    on: function (name, fn) {
      (listeners[name] = listeners[name] || []).push(fn);
      return function () {
        var list = listeners[name] || [];
        var i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
      };
    },
    info: function () { return post("device.info"); },
    /* Declare, ahead of time, how the system back gesture should be answered:
       "pass" leaves with the normal animation, "capture" fires the "back"
       event so the page decides, "block" swallows it. Declared on state
       changes (menu, game, cutscene), never during the gesture: the platform
       has to know before it starts. Three presses inside three seconds leave
       regardless, so a page cannot trap the user. */
    back: function (mode) { return post("back.mode", { mode: mode || "pass" }); },
    /* Ask the host to close the app. -- Not reachable from a browser tab. */
    exit: function () { return post("back.exit"); },
    /* Keep the display lit while the page is in front. The host also clears it
       on pause, so this never survives a trip to the launcher. */
    keepAwake: function (on) { return post("screen.keepAwake", { on: on !== false }); },
    /* Hide the system bars (immersive). A <video> going full screen on its own
       is handled by the host and needs no call; this is for pages that want the
       whole screen for something else. */
    fullscreen: function (on) { return post("screen.fullscreen", { on: on !== false }); },
    /* Durable reminders. Whoever knows the time in advance uses this: the
       entry is stored on the device, survives a reboot, and fires even with
       the app closed. Nothing here talks to a server.
         schedule.add({id, at:"HH:MM", repeat:"once"|"daily", title, body,
                       kind:"alarm"|"reminder", link})
       The answer carries the honest mode: "native" when the platform holds
       the time, "none" when it cannot (a browser tab), "server" when a future
       build hands the job to the cockpit. `exact` says whether the trigger is
       guaranteed to the minute. */
    schedule: {
      add: function (o) { return post("schedule.add", o || {}); },
      list: function () { return post("schedule.list"); },
      cancel: function (id) { return post("schedule.cancel", { id: id }); },
      state: function () { return post("schedule.state"); },
      /* Kept for pages written before the split; schedule.* is the name. */
      supported: function () { return post("schedule.state"); }
    },
    /* Delivery only: show a notification now, if the app may. Nothing is
       stored, so a dismissed banner is gone for good.
         notify.show({tag, title, body, kind?})
       A tap fires the "notify.tap" event with {id, kind, deepLink}. */
    notify: {
      show: function (o) { return post("notify.show", o || {}); },
      dismiss: function (tag) { return post("notify.dismiss", { tag: tag }); },
      permission: function () { return post("notify.permission"); }
    },
    /* Reactive messages: something outside the app decides, right now, that
       the user should be told. Needs a build with push and a server that knows
       the device; listen with Shell.on("push.message", fn). */
    push: {
      register: function () { return post("push.register"); }
    }
  };
})();
