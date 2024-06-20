#!/usr/bin/env bash

######################################################################
# generate github summary page of all the testings
# /tr 2024-06-17
######################################################################

function output() {
  echo -e $* >> "out-$logfile.md"
}

function outfile() {
  if [ -f $1 ]; then
    CUR=`stat --printf="%s" "out-$logfile.md"`
    ADD=`stat --printf="%s" "$1"`
    X=$((CUR+ADD))
    if [ $X -lt $((1024*1023)) ]; then
      cat "$1" >> "out-$logfile.md"
    else
      logfile=$((logfile+1))
      cat "$1" >> "out-$logfile.md"
    fi
  fi
}

function showfile() {
  filename="$1"
  headline="$2"
  echo "<details><summary>$headline</summary><pre>" > tmp
  cat $filename >> tmp
  echo "</pre></details>" >> tmp
  outfile tmp
  rm -f tmp
}

function send2github() {
  test -f "$1" && dd if="$1" bs=1023k count=1 >> $GITHUB_STEP_SUMMARY
}

# generate summary of one test
function generate() {
  VMs=3
  ####################################################################
  # osname.txt                       -> used for headline
  # disk-before.txt                  -> used together with uname
  # disk-afterwards.txt              -> used together with uname
  # vm{1,2,3}log.txt (colored, used when current/log isn't there)
  ####################################################################
  # vm{1,2,3}/uname.txt              -> used once
  # vm{1,2,3}/build-stderr.txt       -> used once
  # vm{1,2,3}/dmesg-prerun.txt       -> used once
  # vm{1,2,3}/dmesg-module-load.txt  -> used once
  # vm{1,2,3}/console.txt            -> all 3 used
  ####################################################################
  # vm{1,2,3}/current/log     -> if not there, kernel panic loading
  # vm{1,2,3}/current/results -> if not there, kernel panic testings
  # vm{1,2,3}/exitcode.txt
  ####################################################################

  # headline of this summary
  output "\n## $headline\n"

  for i in `seq 1 $VMs`; do
    if [ -s vm$i/uname.txt ]; then
      output "<pre>"
      outfile vm$i/uname.txt
      output "\nVM disk usage before:"
      outfile disk-afterwards.txt
      output "\nand afterwards:"
      outfile disk-before.txt
      output "</pre>"
      break
    fi
  done

  for i in `seq 1 $VMs`; do
    if [ -s vm$i/build-stderr.txt ]; then
      showfile "vm$i/build-stderr.txt" "Module build (stderr output)"
      break
    fi
  done

  for i in `seq 1 $VMs`; do
    if [ -s vm$i/dmesg-prerun.txt ]; then
      showfile "vm$i/dmesg-prerun.txt" "Dmesg output - before tests"
      break
    fi
  done

  for i in `seq 1 $VMs`; do
    if [ -s vm$i/dmesg-module-load.txt ]; then
      showfile "vm$i/dmesg-module-load.txt" "Dmesg output - module loading"
      break
    fi
  done

  for i in `seq 1 $VMs`; do
    log="vm$i/current/log"
    if [ ! -f $log ]; then
      output ":exclamation: Logfile of vm$i tests is missing :exclamation:"

      # some out may be generated
      if [ -s vm${i}log.txt ]; then
        cat vm${i}log.txt | \
          sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" > "vm${i}log"
        showfile "vm${i}log" "Generated tests output of vm$i"
      fi

      # output the console contents and continue with next vm
      if [ -s "vm$i/console.txt" ]; then
        cat "vm$i/console.txt" | \
          sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" > "vm${i}log"
        showfile "vm${i}log" "Serial console output of vm$i"
      fi

      rm -f "vm${i}log"
      continue
    fi

    cat $log | grep '^Test[: ]' > tests.txt
    results="vm$i/current/results"
    if [ ! -s "$results" ]; then
      output ":exclamation: Results file of vm$i tests is missing :exclamation:"
      # generate results file from log
      ./zts-report.py --no-maybes ./tests.txt > $results
      # Running Time:	01:30:09
      # Running Time:	not finished!!
      echo -e "\nRunning Time:\tKernel panic!" >> $results
    fi
    cat $results | awk '/Results Summary/ { show=1; print; next; } show' > summary.txt
    runtime=`cat $results | grep '^Running Time:' | cut -f2`

    awk '/\[FAIL\]|\[KILLED\]/{ show=1; print; next; } \
      /\[SKIP\]|\[PASS\]/{ show=0; } show' $log > debug.txt

    output "\n### Tests on vm$i ($runtime)\n\n"

    if [ -s summary.txt ]; then
      showfile "summary.txt" "Summary of all tests"
    fi

    if [ -s "vm$i/console.txt" ]; then
      showfile "vm$i/console.txt" "Serial console output"
    fi

    if [ -s tests.txt ]; then
      showfile "tests.txt" "List of all tests"
    fi

    MAX="300"
    if [ -s debug.txt ]; then
      S=`stat --printf="%s" "debug.txt"`
      if [ $S -gt $((1024*$MAX)) ]; then
        dd if=debug.txt of=debug.txt2 count=$MAX bs=1024 2>/dev/null
        mv -f debug.txt2 debug.txt
        echo "..." >> debug.txt
        echo "!!! THIS FILE IS BIGGER !!!" >> debug.txt
        echo "Please download the zip archiv for full content!" >> debug.txt
      fi
      showfile "debug.txt" "Debug list for failed tests (vm$i, $runtime)"
    fi
  done
}

# functional tests via qemu
function summarize() {
  for tarfile in Logs-functional-*/qemu-*.tar; do
    rm -rf vm* *.txt
    tar xf "$tarfile"
    osname=`cat osname.txt`
    headline="Functional Tests: $osname"
    generate
  done
}

# https://docs.github.com/en/enterprise-server@3.6/actions/using-workflows/workflow-commands-for-github-actions#step-isolation-and-limits
# Job summaries are isolated between steps and each step is restricted to a maximum size of 1MiB.
# [ ] can not show all error findings here
# [x] split files into smaller ones and create additional steps

# first call, generate all summaries
if [ ! -f out-0.md ]; then
  # create ./zts-report.py for generate()
  TEMPLATE="tests/test-runner/bin/zts-report.py.in"
  cat $TEMPLATE| sed -e 's|@PYTHON_SHEBANG@|python3|' > ./zts-report.py
  chmod +x ./zts-report.py

  logfile="0"
  summarize
  send2github out-0.md
else
  send2github out-$1.md
fi

exit 0
