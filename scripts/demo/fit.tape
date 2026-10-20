# Rows fit a narrow window; resting on a cut cell shows the whole row in a float.
Output docs/demo/fit.gif
Source scripts/demo/settings.tape

Hide
Type "ADO_DEMO_OPEN=area $NVIM -u scripts/demo/init.lua"
Enter
Sleep 1.5s
Show

Sleep 1s
Type ":botright vnew | wincmd p | vertical resize 60"
Enter
Sleep 2s
Type "j03f│w"
Sleep 2s
Type "j"
Sleep 2s
Type "jj"
Sleep 2.5s
