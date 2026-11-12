# run.sh ENGINE DIR PARALLEL [extra]
s=$(date +%s.%N); ./tc_$1 $2/Payload id/cert.p12 id/test.mobileprovision pw $3 $4 > $2.log 2>&1; rc=$?; e=$(date +%s.%N)
printf "%s rc=%s %.1fs %s\n" "$1" "$rc" "$(echo "$e - $s" | bc)" "$(grep -a -o 'SIGN_RESULT=.\|TAMPER_SEAL_CHECK=.' $2.log | tr '\n' ' ')"
