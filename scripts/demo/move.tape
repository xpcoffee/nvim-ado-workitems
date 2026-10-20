# dd and p move a row to another area; yy and p under Children give it a parent.
Output docs/demo/move.gif
Source scripts/demo/settings.tape

Hide
Type "ADO_DEMO_OPEN=area $NVIM -u scripts/demo/init.lua"
Enter
Sleep 1.5s
Show

Sleep 800ms
Type "5j"
Sleep 400ms
Type "dd"
Sleep 800ms
Type "-"
Sleep 1s
Type "j"
Enter
Sleep 1.2s
Type "p"
Sleep 1s
Type "3j"
Enter
Sleep 1.5s
Ctrl+W
Type "kj"
Sleep 300ms
Type "yy"
Sleep 800ms
Ctrl+W
Type "j"
Sleep 300ms
Type "/Children"
Enter
Sleep 300ms
Type "p"
Sleep 1.2s
Type ":w"
Enter
Sleep 3s
Type "y"
Sleep 3s
