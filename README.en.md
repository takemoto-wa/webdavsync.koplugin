# WebDAV Sync Plugin (webdavsync.koplugin) v2.4

A KOReader plugin for screenshot upload, multi-device reading progress sync, and multi-device annotation (highlight/note) sync — all using the WebDAV cloud storage already configured in KOReader.

## Installation
1. Copy the entire `webdavsync.koplugin` folder into `koreader/plugins/` on both devices, then restart KOReader.
2. Configure a WebDAV account in KOReader's "Cloud storage" first (Nutstore is already configured on this device).

## Feature 1: Screenshot Upload
1. Go to **Tools** > **WebDAV Sync Plugin** > **Upload screenshots to cloud**.
2. You can also bind a gesture: Settings > Gesture Manager > pick any gesture > action "Upload screenshots to cloud" (in the **General** section).
3. Only new PNGs not yet recorded in `settings/webdavsync_upload.lua` are uploaded. Tap again any time to pick up the remaining ones.

## Feature 2: Multi-device Reading Progress Sync
1. **Tools** > **WebDAV Sync Plugin** > **Reading progress sync** submenu:
   - Upload current reading progress
   - Pull reading progress from cloud
   - Auto-sync toggle (on by default)
2. With auto-sync on: opening a book compares local and cloud progress and keeps whichever is further ahead; progress is uploaded 8 seconds after a page turn and when the book is closed.
3. Gestures can also be bound to "Upload reading progress" and "Pull reading progress" (in the **Reader** section).

## Feature 3: Multi-device Annotation (Highlight/Note) Sync
1. **Tools** > **WebDAV Sync Plugin** > **Annotation sync** submenu:
   - Upload this book's annotations to cloud
   - Pull annotations from cloud
2. Gestures can also be bound to "Upload annotations" and "Pull annotations" (in the **Reader** section).
3. This syncs KOReader's native `annotations` data (highlight position, color, text and notes). Highlights refresh immediately after a pull.

## Annotation Conflict Rules (since v2.4)
- On pull, annotations are compared entry by entry with the local set: if the content is identical, nothing changes.
- When annotations differ, they are **merged, never replaced**:
  - Local annotations are the base; cloud-only annotations are appended to the local list. Existing local annotations are kept unchanged.
  - The merged set is written locally and **uploaded straight back to the cloud**, so the cloud copy is always the most complete one.
  - A manual "Upload annotations" also merges cloud content first, so it can never shrink the cloud set.
- An annotation is identified by its position in the book + highlight style + text, so re-pulling or a different order never creates duplicates.
- Annotation records are stored at account `url` + `koreader-annotations/<book-digest>.json`, shared by both devices for the same book.
- Annotation sync is manual and never runs automatically while reading, so it won't interrupt your session.

## Fixed in v2.4
- Fixed a freeze/crash after pulling annotations: the old version queued an invalid `flash` refresh mode, which made `uimanager.lua` fail when the menu closed. It now uses the valid `ui` mode.

## Progress Sync Rules
- Books are matched by document checksum (`partial_md5_checksum`, falling back to the MD5 of the filename); both devices must have the same file.
- Progress records are stored at account `url` + `koreader-progress/<book-digest>.txt`, containing position, percentage, timestamp and device.
- On pull: a manual pull always jumps to the cloud position (with a notice if the cloud record came from this device); an automatic pull compares local and cloud progress — paginated documents by page number, flow documents by percentage — and keeps whichever is further ahead. If local is ahead, it stays and is pushed back to the cloud so all devices converge on the fastest progress.
- Paginated documents (PDF/DJVU) jump by page number; flow documents (EPUB, etc.) jump by XPointer.

## General Notes
- Address, username, password and remote directory are all read automatically from `settings/cloudstorage.lua`; the plugin does not store credentials itself.
- If there are multiple WebDAV accounts, the one with the largest `order` is used; if there is only one, that one is used.
- The auto-sync toggle is recorded in `settings/webdavsync_settings.lua`.
