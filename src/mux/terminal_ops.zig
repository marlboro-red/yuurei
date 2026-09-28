//! Operations applied identically to the authoritative terminal and its replica.
const Terminal = @import("../terminal/main.zig").Terminal;

/// Return whether the shell needs a form-feed to repaint its prompt.
pub fn clear(term: *Terminal, history: bool) bool {
    // If we're on the alternate screen, we do not clear. Since this is an
    // emulator-level screen clear, this messes up the running programs
    // knowledge of where the cursor is and causes rendering issues. So,
    // for alt screen, we do nothing.
    if (term.screens.active_key == .alternate) return false;

    // Clear our selection
    term.screens.active.clearSelection();

    // Clear our scrollback
    if (history) term.eraseDisplay(.scrollback, false);

    // If we're not at a prompt, we just delete above the cursor.
    if (!term.cursorIsAtPrompt()) {
        if (term.screens.active.cursor.y > 0) {
            term.screens.active.eraseActive(
                term.screens.active.cursor.y - 1,
            );
        }

        // Clear all Kitty graphics state for this screen. This copies
        // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
        // didn't spend time researching whether it only deletes Kitty
        // graphics that are placed above the cursor or if it deletes
        // all of them. We delete all of them for now but if this behavior
        // isn't fully correct we should fix this later.
        term.screens.active.kitty_images.delete(
            term.io(),
            term.screens.active.alloc,
            term,
            .{ .all = true },
        );

        return false;
    }

    // At a prompt, we want to first fully clear the screen, and then after
    // send a FF (0x0C) to the shell so that it can repaint the screen.
    // Mark the current row as a not a prompt so we can properly
    // clear the full screen in the next eraseDisplay call.
    // TODO: fix this
    // term.markSemanticPrompt(.command);
    // assert(!term.cursorIsAtPrompt());
    term.eraseDisplay(.complete, false);
    return true;
}
