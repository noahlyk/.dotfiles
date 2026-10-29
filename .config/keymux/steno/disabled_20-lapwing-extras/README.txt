Lapwing's Emily's symbols, Emily's modifiers and Jeff's phrasing, for keymux.

These are Python dictionaries, which keymux does not run. regenerate.py turns each .py here
into a .json beside it, which keymux reads (and reloads the moment it changes):

    python3 regenerate.py            # all of them, about 20 seconds each
    python3 regenerate.py 04-lapwing-emilys-symbols.py

Edit a .py (add your own symbols to Emily's, say), then run regenerate.py. The numbers in the
names are the order Lapwing loads them in, and they matter: Jeff's phrasing overrides some of
Lapwing's own entries. This whole folder is numbered 20, so it is above the Lapwing theory and
your plain files, and below 00-user.json.

05-lapwing-first-up-movement.json (from make-first-up.py) marks the #TPH- movement chords {:firstup}:
hold #TPH and tap R, P, B... again and again to keep moving. Run make-first-up.py after a new Lapwing download.
