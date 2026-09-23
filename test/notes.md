echo '' |./repl post
#$=0

echo '(sleep 5 && ls)'| timeout 1 ./repl post
#$=0

./repl stop
#$=0

echo sleep 5 |./repl post
echo Ok |timeout 1 ./repl send
#$=1
#->expect tiemout
echo Ok |./repl send
#$=0
#-> expect 'Ok' in several seconds

