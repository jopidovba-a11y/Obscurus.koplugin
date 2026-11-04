# Obscurus

A home screen dashboard for KOReader with a 1-bit look: framed windows, dithered shadows, dotted book covers, reading statistics and a file explorer.

Portrait only. In landscape it pauses itself and comes back when you rotate.

<table align="center">
  <tr>
    <td align="center" valign="middle">
      <img width="300" alt="IMG_20261104_161316" src="https://github.com/user-attachments/assets/f375e79d-0bb4-43a8-8372-58eb124c884c" />
    </td>
    <td align="center" valign="middle">
      <img width="300" alt="FileManager_2026-11-04_085628" src="https://github.com/user-attachments/assets/70ad402d-34f5-4641-b787-3a213d78bc2e" />
    </td>
  </tr>
  <tr>
    <td align="center" valign="middle">
      <img width="300" alt="FileManager_2026-11-04_085542" src="https://github.com/user-attachments/assets/351fb762-02f5-4e1e-b1d7-d83580c11958" />
    </td>
    <td align="center" valign="middle">
      <img width="300" alt="FileManager_2026-11-04_085514" src="https://github.com/user-attachments/assets/f5f46799-a1a5-48f3-9889-2f7f9d59c830" />
    </td>
  </tr>
</table>
## Features

- Current book card with cover, title and progress
- Library bar on the right with your home folder's books, sorted by recent
- Statistics and file explorer, one tap away from the skull window
- Movable and resizable windows you can add anywhere.
- Dithered covers can be switched on or off for the recent book, the right bar and the explorer.

## Install

1. Copy the `obscurus.koplugin` folder to `koreader/plugins/`.
2. Restart KOReader.
3. Open the File Manager menu, go to **Obscurus** and tick **Enable as home screen**.

## Usage

- Tap a cover to open the book. Use the arrows to move through the library (for the recent book cover tap the text or the loading bar instead, the cover tap is disabled to allow gestures in that corner).

- Hold on an empty spot to add a window. Hold on a window to move, resize or close it. 

- The **statistics** and **explorer** tabs are in the title bar of the skull window.

The covers in the right bar belong to your home folder. The recent book in the card bellow won't appear if it is inside a hidden folder, this is intentional. 

**Required plugins:**

- **Reading statistics** must be enabled for the statistics to work.
- **Cover Browser** must be enabled for the covers to work.

If you disable Koreader's default plugins (as I do), remember to turn these
two back on.
