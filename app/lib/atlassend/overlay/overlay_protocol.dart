/// Message protocol between the main engine and the overlay engine.
///
/// Both engines live in one process but in separate isolate groups, so they
/// talk through `IsolateNameServer` + `SendPort`. Only primitives, lists and
/// `SendPort`s cross that boundary, hence every message is a plain list whose
/// first element is one of the type tags below.
library;

/// Name under which the MAIN isolate registers its receive port.
const kOverlayMainPortName = 'atlassend.overlay.main';

/// Method channel on the main engine handled by the Windows runner (start / stop the overlay).
const kOverlayHostChannel = 'atlassend/overlay_host';

/// Method channel on the overlay engine handled by the Windows runner (window region / visibility).
const kOverlayWindowChannel = 'atlassend/overlay_window';

// --- main -> overlay -------------------------------------------------------

/// `[config, bg, surface, text, muted, accent, frame, doneLabel, failedLabel, openingLabel]`, colors as ARGB ints.
const kMsgConfig = 'config';

/// `[add, cardId, title, subtitle, badge, fling]`.
/// `fling` is `null` (default entry from the bottom edge) or `[x, velocity, angle]` (phase 3).
const kMsgAdd = 'add';

/// `[progress, cardId, fraction]` with fraction in 0..1.
const kMsgProgress = 'progress';

/// `[done, cardId]`.
const kMsgDone = 'done';

/// `[fail, cardId, message]`.
const kMsgFail = 'fail';

/// `[remove, cardId]`: the transfer vanished without a result (declined, session closed).
const kMsgRemove = 'remove';

// --- overlay -> main -------------------------------------------------------

/// `[ready, SendPort]`: the overlay isolate is up and listens on the given port.
const kMsgReady = 'ready';

/// `[open, cardId]`: the card was clicked.
const kMsgOpen = 'open';

/// `[reveal, cardId]`: "show in folder" was requested.
const kMsgReveal = 'reveal';

/// `[idle]`: the last card disappeared, the overlay window is hidden.
const kMsgIdle = 'idle';
