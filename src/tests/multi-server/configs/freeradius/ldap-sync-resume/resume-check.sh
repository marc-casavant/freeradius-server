#!/bin/bash
#
#  Run FreeRADIUS for the `ldap-sync-resume` test, and check FreeRADIUS
#  after each reconnect to the OpenLDAP server (slapd).
#
#  Usage:
#    resume-check.sh run
#    resume-check.sh check <reconnect> <reconnects> <users> <window>
#    resume-check.sh summary <reconnects> <users> <stop window>
#
#  `run` runs FreeRADIUS in the foreground and stores the exit status of
#  FreeRADIUS.  In profiling mode, `run` runs the capture script in
#  `RADIUSD_COMMAND`.  The capture script runs FreeRADIUS under the
#  profiler and stores the exit status.  `check` calls `run` to start
#  FreeRADIUS.
#
#  `check` starts FreeRADIUS when FreeRADIUS is not running.  `check` then
#  waits up to <window> seconds for the changes of one resumed sync.
#  slapd sends one `Add` and one `Present` for each of the <users>
#  accounts.  `check` then appends the line
#
#    sync-resumed-<reconnect> {"ok": N, "status": "<text>"}
#
#  to the file that the test framework watches.  `ok` is 1 when FreeRADIUS
#  is running and received every change.  <reconnect> 0 is the start of
#  FreeRADIUS.
#
#  When FreeRADIUS is not running, `check` appends the following line
#  before the `sync-resumed-<reconnect>` line
#
#    freeradius-exited {"reconnect": N, "status": "<text>", "error": "<text>", "log": "<path>"}
#
#  `error` is the failed assertion or the talloc abort that FreeRADIUS
#  logged.  `log` is the path on the host of
#  `failures/exit-<reconnect>-<restart>.log`, a copy of the log of
#  FreeRADIUS.  Because `make` prints the last 200 lines of every file
#  directly under the log directory when the test fails, the copies are
#  in a subdirectory.
#
#  When FreeRADIUS is running and did not receive every change, `check`
#  appends a `freeradius-stalled` line before the
#  `sync-resumed-<reconnect>` line.  The `freeradius-stalled` line has
#  the fields of the `freeradius-exited` line.  `log` is the path of
#  `failures/stall-<reconnect>-<restart>.log`.  In service
#  mode, `failures/stall-<reconnect>-<restart>-backtrace.txt` holds a
#  backtrace of every thread.
#
#  After an exit or a stall, `check` starts FreeRADIUS again and checks the
#  first resume of the new process, up to three times.  Each of those
#  resumes that fails adds one more `freeradius-exited` or
#  `freeradius-stalled` line.
#
#  `summary` appends four lines and then stops FreeRADIUS:
#
#    test-logs     <path on the host of the `failures` directory>
#    test-expected 0 exits, 0 stalls, N LDAP user changes at N/N reconnects
#    test-actual   N exits, N stalls, N LDAP user changes at N/N reconnects
#    test-result   <PASSED|FAILED>
#
#  `test-expected` is the result that a pass needs, and `test-actual` is
#  the result of the test in the same form.  An LDAP user change is one
#  `Add` or one `Present` that slapd sends for an account.  `N/N` is the
#  number of reconnects after which FreeRADIUS was running and had
#  received every LDAP user change.  `test-result` is `PASSED` when
#  FreeRADIUS did not exit and did not stall.
#
#  A profiler runs FreeRADIUS under another process name.  The script
#  finds FreeRADIUS by the command line `freeradius -f`, which every mode
#  uses.
#
set -u

action=$1

events=/tmp/sync-events.log
mark=/tmp/sync-events.mark
fifo=/tmp/freeradius-run.fifo
failures=/var/log/freeradius/failures
triggers="/var/run/multi-server/${TEST_PROJECT_NAME}.txt"

if [ -n "${RADIUSD_COMMAND:-}" ]; then
	log="$PROFILING_RESULT_DIR/freeradius.log"
	exit_status="$PROFILING_RESULT_DIR/exit-status"
else
	log=/var/log/freeradius/radius.log
	exit_status=/tmp/freeradius-exit-status
fi

server_pids() {
	pgrep -f '[f]reeradius -f'
}

profiler_pids() {
	pgrep -f '[s]tart_[a-z]*_profiling.sh'
}

#
#  Read lines of the change log (`$events`) from line <first>, as
#  FreeRADIUS writes the lines.  Stop after <count> lines, after <window>
#  seconds, or when the process <pid> exits.  Then set `changes_read` to
#  the number of lines read.
#
wait_changes() {
	changes_read=0
	while IFS= read -r _; do
		changes_read=$((changes_read + 1))
		if [ "$changes_read" -ge "$2" ]; then
			break
		fi
	done < <(timeout "$3" tail -n "+$1" -F ${4:+--pid="$4"} "$events" 2> /dev/null)
}

#
#  Start FreeRADIUS with an empty change log.  `run` writes the ID of the
#  process that `run` started to the FIFO (`$fifo`).  `start_server` then
#  sets `run_pid` to the ID.
#
start_server() {
	if [ -z "${RADIUSD_COMMAND:-}" ]; then
		rm -f "$log"
	fi
	rm -f "$events" "$fifo"
	touch "$events"
	mkfifo "$fifo"
	setsid bash "$0" run > /dev/null 2>&1 < /dev/null &
	run_pid=$(timeout 20 cat "$fifo")
}

#
#  Print how FreeRADIUS exited, from the stored exit status.
#
describe_exit() {
	local code

	code=$(cat "$exit_status" 2> /dev/null)
	case "$code" in
	134)
		echo "FreeRADIUS aborted (SIGABRT, exit status 134)"
		;;
	139)
		echo "FreeRADIUS had a segmentation fault (SIGSEGV, exit status 139)"
		;;
	"")
		echo "FreeRADIUS exited with an unknown status"
		;;
	*)
		echo "FreeRADIUS exited with status $code"
		;;
	esac
}

case "$action" in
run)
	rm -f "$exit_status"
	${RADIUSD_COMMAND:-freeradius -f -l /var/log/freeradius/radius.log} &
	child=$!
	if [ -p "$fifo" ]; then
		(echo "$child" > "$fifo") &
	fi
	wait "$child"
	code=$?
	if [ -z "${RADIUSD_COMMAND:-}" ]; then
		echo "$code" > "$exit_status"
	fi
	exit 0
	;;

check)
	reconnect=$2
	reconnects=$3
	users=$4
	window=$5

	want=$((2 * users))
	if [ "$reconnect" -eq 0 ]; then
		label="start"
	else
		label="reconnect $reconnect of $reconnects"
	fi

	run_pid=$(cat /tmp/freeradius-run.pid 2> /dev/null)
	first=1
	if [ -f "$mark" ]; then
		first=$(($(cat "$mark") + 1))
	fi
	if [ -z "$(server_pids)" ]; then
		start_server
		first=1
	fi

	ok=1
	restarts=0
	while true; do
		wait_changes "$first" "$want" "$window" "$run_pid"
		received=$changes_read
		pids=$(server_pids)
		if [ -n "$pids" ] && [ "$received" -ge "$want" ]; then
			break
		fi

		ok=0
		mkdir -p "$failures"
		if [ -z "$pids" ]; then
			kind=exited
			copy="exit-$reconnect-$restarts.log"
			error=$(grep -a 'ASSERT FAILED\|talloc abort' "$log" | tail -1 | tr -d '"\\')
			status="$label: $(describe_exit) after $received of $want LDAP user changes"
		else
			kind=stalled
			copy="stall-$reconnect-$restarts.log"
			error="FreeRADIUS did not receive every LDAP user change"
			if [ -z "${RADIUSD_COMMAND:-}" ]; then
				gdb -batch -ex 'thread apply all bt 12' -p "$(echo "$pids" | head -1)" \
					> "$failures/stall-$reconnect-$restarts-backtrace.txt" 2>&1
				error="$error, see failures/stall-$reconnect-$restarts-backtrace.txt"
			fi
			status="$label: FreeRADIUS is running and received $received of $want LDAP user changes in $window seconds"
			kill -9 $pids 2> /dev/null
		fi
		cp "$log" "$failures/$copy"
		echo "freeradius-$kind {\"reconnect\": $reconnect, \"status\": \"$status\", \"error\": \"${error:-the log of FreeRADIUS does not have a failed assertion or a talloc abort}\", \"log\": \"$TEST_LOG_DIR/failures/$copy\"}" >> "$triggers"
		if [ -z "${failure:-}" ]; then
			failure=$status
		fi

		if [ "$restarts" -ge 3 ]; then
			break
		fi
		restarts=$((restarts + 1))
		label="restart $restarts after reconnect $reconnect of $reconnects"

		#
		#  The capture script writes the profile after FreeRADIUS
		#  exits, and has to finish before FreeRADIUS starts again.
		#
		for pid in $(profiler_pids); do
			timeout "$window" tail --pid="$pid" -f /dev/null
		done
		start_server
		first=1
	done

	echo "$run_pid" > /tmp/freeradius-run.pid
	wc -l < "$events" > "$mark"
	if [ "$ok" -eq 1 ]; then
		echo "sync-resumed-$reconnect {\"ok\": 1, \"status\": \"$label: FreeRADIUS is running and received $want of $want LDAP user changes\"}" >> "$triggers"
	else
		echo "sync-resumed-$reconnect {\"ok\": 0, \"status\": \"$failure\"}" >> "$triggers"
	fi
	exit 0
	;;

summary)
	reconnects=$2
	users=$3
	stop_window=$4

	want=$((2 * users))
	exits=$(grep -c '^freeradius-exited ' "$triggers")
	stalls=$(grep -c '^freeradius-stalled ' "$triggers")
	complete=$(grep -c '^sync-resumed-[1-9][0-9]* {"ok": 1' "$triggers")
	if [ "$exits" -eq 0 ] && [ "$stalls" -eq 0 ]; then
		result=PASSED
	else
		result=FAILED
	fi
	{
		echo "test-logs     $TEST_LOG_DIR/failures"
		echo "test-expected 0 exits, 0 stalls, $want LDAP user changes at $reconnects/$reconnects reconnects"
		echo "test-actual   $exits exits, $stalls stalls, $want LDAP user changes at $complete/$reconnects reconnects"
		echo "test-result   $result"
	} >> "$triggers"

	for pid in $(server_pids) $(profiler_pids); do
		kill "$pid" 2> /dev/null
		timeout "$stop_window" tail --pid="$pid" -f /dev/null
	done
	kill -9 $(server_pids) 2> /dev/null
	exit 0
	;;

*)
	echo "resume-check.sh: unknown action \"$action\"" >&2
	exit 1
	;;
esac
