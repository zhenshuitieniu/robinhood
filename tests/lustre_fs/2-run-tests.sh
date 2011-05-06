#/bin/sh

ROOT="/mnt/lustre"

BKROOT="/tmp/backend"
RBH_OPT=""

XML="test_report.xml"
TMPXML_PREFIX="/tmp/report.xml.$$"
TMPERR_FILE="/tmp/err_str.$$"

TEMPLATE_DIR='../../doc/templates'

if [[ ! -d $ROOT ]]; then
	echo "Creating directory $ROOT"
	mkdir -p "$ROOT"
else
	echo "Creating directory $ROOT"
fi

if [[ -z "$PURPOSE" || $PURPOSE = "LUSTRE_HSM" ]]; then
	is_lhsm=1
	is_hsmlite=0
	shook=0
	RH="../../src/robinhood/rbh-hsm $RBH_OPT"
	REPORT=../../src/robinhood/rbh-hsm-report
	CMD=rbh-hsm
	PURPOSE="LUSTRE_HSM"
	ARCH_STR="Start archiving"
elif [[ $PURPOSE = "TMP_FS_MGR" ]]; then
	is_lhsm=0
	is_hsmlite=0
	shook=0
	RH="../../src/robinhood/robinhood $RBH_OPT"
	REPORT="../../src/robinhood/rbh-report $RBH_OPT"
	CMD=robinhood
elif [[ $PURPOSE = "HSM_LITE" ]]; then
	is_lhsm=0
	is_hsmlite=1

	if [[ "x$SHOOK" != "x1" ]]; then
		shook=0
	else
		shook=1
	fi

	RH="../../src/robinhood/rbh-hsmlite $RBH_OPT"
	REPORT="../../src/robinhood/rbh-hsmlite-report $RBH_OPT"
	RECOV="../../src/robinhood/rbh-hsmlite-recov $RBH_OPT"
	CMD=rbh-hsmlite
	ARCH_STR="Starting backup"
	if [ ! -d $BKROOT ]; then
		mkdir -p $BKROOT
	fi
fi

function flush_data
{
	if [[ -n "$SYNC" ]]; then
	  # if the agent is on the same node as the writter, we are not sure
	  # data has been flushed to OSTs
	  echo "Flushing data to OSTs"
	  sync
	fi
}

if [[ -z "$NOLOG" || $NOLOG = "0" ]]; then
	no_log=0
else
	no_log=1
fi

PROC=$CMD
CFG_SCRIPT="../../scripts/rbh-config"

CLEAN="rh_chglogs.log rh_migr.log rh_rm.log rh.pid rh_purge.log rh_report.log report.out rh_syntax.log recov.log rh_scan.log"

SUMMARY="/tmp/test_${PROC}_summary.$$"

NB_ERROR=0
RC=0
SKIP=0
SUCCES=0
DO_SKIP=0

function error_reset
{
	NB_ERROR=0
	DO_SKIP=0
	cp /dev/null $TMPERR_FILE
}

function error
{
	echo "ERROR $@"
 	grep -i error *.log
	NB_ERROR=$(($NB_ERROR+1))

	if (($junit)); then
	 	grep -i error *.log >> $TMPERR_FILE
		echo "ERROR $@" >> $TMPERR_FILE
	fi
}

function set_skipped
{
	DO_SKIP=1
}

function clean_logs
{
	for f in $CLEAN; do
		if [ -s $f ]; then
			cp /dev/null $f
		fi
	done
}


function wait_done
{
	max_sec=$1
	sec=0
	if [[ -n "$MDS" ]]; then
#		cmd="ssh $MDS egrep 'WAITING|RUNNING|STARTED' /proc/fs/lustre/mdt/lustre-MDT0000/hsm/agent_actions"
		cmd="ssh $MDS egrep -v SUCCEED|CANCELED /proc/fs/lustre/mdt/lustre-MDT0000/hsm/agent_actions"
	else
#		cmd="egrep 'WAITING|RUNNING|STARTED' /proc/fs/lustre/mdt/lustre-MDT0000/hsm/agent_actions"
		cmd="egrep -v SUCCEED|CANCELED /proc/fs/lustre/mdt/lustre-MDT0000/hsm/agent_actions"
	fi

	action_count=`$cmd | wc -l`

	if (( $action_count > 0 )); then
		echo "Current actions:"
		$cmd

		echo -n "Waiting for copy requests to end."
		while (( $action_count > 0 )) ; do
			echo -n "."
			sleep 1;
			((sec=$sec+1))
			(( $sec > $max_sec )) && return 1
			action_count=`$cmd | wc -l`
		done
		$cmd
		echo " Done ($sec sec)"
	fi

	return 0
}



function clean_fs
{
	if (( $is_lhsm != 0 )); then
		echo "Cancelling agent actions..."
		if [[ -n "$MDS" ]]; then
			ssh $MDS "echo purge > /proc/fs/lustre/mdt/*/hsm_control"
		else
			echo "purge" > /proc/fs/lustre/mdt/*/hsm_control
		fi

		echo "Waiting for end of data migration..."
		wait_done 60
	fi

	echo "Cleaning filesystem..."
	if [[ -n "$ROOT" ]]; then
		 find "$ROOT" -mindepth 1 -delete 2>/dev/null
	fi

	if (( $is_hsmlite != 0 )); then
		if [[ -n "$BKROOT" ]]; then
			echo "Cleaning backend content..."
			find "$BKROOT" -mindepth 1 -delete 2>/dev/null 
		fi
	fi

	echo "Destroying any running instance of robinhood..."
	pkill robinhood
	pkill rbh-hsm

	if [ -f rh.pid ]; then
		echo "killing remaining robinhood process..."
		kill `cat rh.pid`
		rm -f rh.pid
	fi
	
	sleep 1
#	echo "Impacting rm in HSM..."
#	$RH -f ./cfg/immediate_rm.conf --readlog --hsm-remove -l DEBUG -L rh_rm.log --once || error ""
	echo "Cleaning robinhood's DB..."
	$CFG_SCRIPT empty_db robinhood_lustre > /dev/null

	echo "Cleaning changelogs..."
	lfs changelog_clear lustre-MDT0000 cl1 0

}

POOL1=ost0
POOL2=ost1
POOL_CREATED=0

function create_pools
{
  if [[ -n "$MDS" ]]; then
	do_mds="ssh $MDS"
  else
	do_mds=""
  fi

  (($POOL_CREATED != 0 )) && return
  $do_mds lfs pool_list lustre | grep lustre.$POOL1 && POOL_CREATED=1
  $do_mds lfs pool_list lustre | grep lustre.$POOL2 && ((POOL_CREATED=$POOL_CREATED+1))
  (($POOL_CREATED == 2 )) && return

  $do_mds lctl pool_new lustre.$POOL1 || error "creating pool $POOL1"
  $do_mds lctl pool_add lustre.$POOL1 lustre-OST0000 || error "adding OST0000 to pool $POOL1"
  $do_mds lctl pool_new lustre.$POOL2 || error "creating pool $POOL2"
  $do_mds lctl pool_add lustre.$POOL2 lustre-OST0001 || error "adding OST0001 to pool $POOL2"
  POOL_CREATED=1
}

function migration_test
{
	config_file=$1
	expected_migr=$2
	sleep_time=$3
	policy_str="$4"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# create and fill 10 files

	echo "1-Modifing files..."
	for i in a `seq 1 10`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=10 >/dev/null 2>/dev/null || error "writing file.$i"
	done

	echo "2-Reading changelogs..."
	# read changelogs
	if (( $no_log )); then
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi

	echo "3-Applying migration policy ($policy_str)..."
	# start a migration files should notbe migrated this time
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error ""

	nb_migr=`grep "$ARCH_STR" rh_migr.log | grep hints | wc -l`
	if (($nb_migr != 0)); then
		error "********** TEST FAILED: No migration expected, $nb_migr started"
	else
		echo "OK: no files migrated"
	fi

	echo "4-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	echo "3-Applying migration policy again ($policy_str)..."
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once

	nb_migr=`grep "$ARCH_STR" rh_migr.log | grep hints | wc -l`
	if (($nb_migr != $expected_migr)); then
		error "********** TEST FAILED: $expected_migr migrations expected, $nb_migr started"
	else
		echo "OK: $nb_migr files migrated"
	fi
}

# migrate a single file
function migration_test_single
{
	config_file=$1
	expected_migr=$2
	sleep_time=$3
	policy_str="$4"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# create and fill 10 files

	echo "1-Modifing files..."
	for i in a `seq 1 10`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=10 >/dev/null 2>/dev/null || error "writing file.$i"
	done

	count=0
	echo "2-Trying to migrate files before we know them..."
	for i in a `seq 1 10`; do
		$RH -f ./cfg/$config_file --migrate-file $ROOT/file.$i -L rh_migr.log -l EVENT 2>/dev/null
		grep "$ROOT/file.$i" rh_migr.log | grep "not known in database" && count=$(($count+1))
	done

	if (( $count == $expected_migr )); then
		echo "OK: all $expected_migr files are not known in database"
	else
		error "$count files are not known in database, $expected_migr expected"
	fi

	cp /dev/null rh_migr.log
	sleep 1

	echo "3-Reading changelogs..."
	# read changelogs
	if (( $no_log )); then
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once 2>/dev/null || error ""
	else
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once 2>/dev/null || error ""
	fi

	count=0
	cp /dev/null rh_migr.log
	echo "4-Applying migration policy ($policy_str)..."
	# files should not be migrated this time: do not match policy
	for i in a `seq 1 10`; do
		$RH -f ./cfg/$config_file --migrate-file $ROOT/file.$i -l EVENT -L rh_migr.log 2>/dev/null
		grep "$ROOT/file.$i" rh_migr.log | grep "whitelisted" && count=$(($count+1))
	done

	if (( $count == $expected_migr )); then
		echo "OK: all $expected_migr files are not eligible for migration"
	else
		error "$count files are not eligible, $expected_migr expected"
	fi

	nb_migr=`grep "$ARCH_STR" rh_migr.log | grep hints | wc -l`
	if (($nb_migr != 0)); then
		error "********** TEST FAILED: No migration expected, $nb_migr started"
	else
		echo "OK: no files migrated"
	fi

	cp /dev/null rh_migr.log
	echo "4-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	count=0
	echo "5-Applying migration policy again ($policy_str)..."
	for i in a `seq 1 10`; do
		$RH -f ./cfg/$config_file --migrate-file $ROOT/file.$i -l EVENT -L rh_migr.log 2>/dev/null
		grep "$ROOT/file.$i" rh_migr.log | grep "successful" && count=$(($count+1))
	done

	if (( $count == $expected_migr )); then
		echo "OK: all $expected_migr files have been migrated successfully"
	else
		error "$count files migrated, $expected_migr expected"
	fi

	nb_migr=`grep "$ARCH_STR" rh_migr.log | grep hints | wc -l`
	if (($nb_migr != $expected_migr)); then
		error "********** TEST FAILED: $expected_migr migrations expected, $nb_migr started"
	else
		echo "OK: $nb_migr files migrated"
	fi
}


function xattr_test
{
	config_file=$1
	sleep_time=$2
	policy_str="$3"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# create and fill 10 files

	echo "1-Modifing files..."
	for i in `seq 1 3`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=10 >/dev/null 2>/dev/null || error "writing file.$i"
	done

	echo "2-Setting xattrs..."
	echo "$ROOT/file.1: xattr.user.foo=1"
	setfattr -n user.foo -v 1 $ROOT/file.1
	echo "$ROOT/file.2: xattr.user.bar=1"
	setfattr -n user.bar -v 1 $ROOT/file.2
	echo "$ROOT/file.3: none"

	# read changelogs
	if (( $no_log )); then
		echo "2-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "2-Reading changelogs..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi

	echo "3-Applying migration policy ($policy_str)..."
	# start a migration files should notbe migrated this time
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error ""

	nb_migr=`grep "$ARCH_STR" rh_migr.log | grep hints | wc -l`
	if (($nb_migr != 0)); then
		error "********** TEST FAILED: No migration expected, $nb_migr started"
	else
		echo "OK: no files migrated"
	fi

	echo "4-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	echo "3-Applying migration policy again ($policy_str)..."
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once

	nb_migr=`grep "$ARCH_STR" rh_migr.log | grep hints |  wc -l`
	if (($nb_migr != 3)); then
		error "********** TEST FAILED: $expected_migr migrations expected, $nb_migr started"
	else
		echo "OK: $nb_migr files migrated"

		if (( $is_hsmlite != 0 )); then
			# checking policy
			nb_migr_arch1=`grep "hints='fileclass=xattr_bar'" rh_migr.log | wc -l`
			nb_migr_arch2=`grep "hints='fileclass=xattr_foo'" rh_migr.log | wc -l`
			nb_migr_arch3=`grep "using policy 'default'" rh_migr.log | wc -l`
			if (( $nb_migr_arch1 != 1 || $nb_migr_arch2 != 1 || $nb_migr_arch3 != 1 )); then
				error "********** wrong policy cases: 1x$nb_migr_arch1/2x$nb_migr_arch2/3x$nb_migr_arch3 (1x1/2x1/3x1 expected)"
				cp rh_migr.log /tmp/xattr_test.$$
				echo "Log saved as /tmp/xattr_test.$$"
			else
				echo "OK: 1 file for each policy case"
			fi
		else
			# checking archive nums
			nb_migr_arch1=`grep "archive_num=1" rh_migr.log | wc -l`
			nb_migr_arch2=`grep "archive_num=2" rh_migr.log | wc -l`
			nb_migr_arch3=`grep "archive_num=3" rh_migr.log | wc -l`
			if (( $nb_migr_arch1 != 1 || $nb_migr_arch2 != 1 || $nb_migr_arch3 != 1 )); then
				error "********** wrong archive_nums: 1x$nb_migr_arch1/2x$nb_migr_arch2/3x$nb_migr_arch3 (1x1/2x1/3x1 expected)"
			else
				echo "OK: 1 file to each archive_num"
			fi
		fi
	fi
	
}

function link_unlink_remove_test
{
	config_file=$1
	expected_rm=$2
	sleep_time=$3
	policy_str="$4"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi
	if (( $no_log )); then
		echo "changelog disabled: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	echo "1-Start reading changelogs in background..."
	# read changelogs
	$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --detach --pid-file=rh.pid || error ""

	sleep 1

	# write file.1 and force immediate migration
	echo "2-Writing data to file.1..."
	dd if=/dev/zero of=$ROOT/file.1 bs=1M count=10 >/dev/null 2>/dev/null || error "writing file.1"

	sleep 1

	if (( $is_hsm != 0 )); then
		echo "3-Archiving file....1"
		flush_data
		lfs hsm_archive $ROOT/file.1 || error "executing lfs hsm_archive"

		echo "3bis-Waiting for end of data migration..."
		wait_done 60 || error "Migration timeout"
	elif (( $is_hsmlite != 0 )); then
		$RH -f ./cfg/$config_file --sync -l DEBUG  -L rh_migr.log || error "executing $CMD --sync"
	fi

	# create links on file.1 files
	echo "4-Creating hard links to $ROOT/file.1..."
	ln $ROOT/file.1 $ROOT/link.1 || error "ln"
	ln $ROOT/file.1 $ROOT/link.2 || error "ln"

	sleep 1

	# removing all files
        echo "5-Removing all links to file.1..."
	rm -f $ROOT/link.* $ROOT/file.1 

	sleep 2
	
	echo "Checking report..."
	$REPORT -f ./cfg/$config_file --deferred-rm --csv -q > rh_report.log
	nb_ent=`wc -l rh_report.log | awk '{print $1}'`
	if (( $nb_ent != $expected_rm )); then
		error "Wrong number of deferred rm reported: $nb_ent"
	fi
	grep "$ROOT/file.1" rh_report.log > /dev/null || error "$ROOT/file.1 not found in deferred rm list"

	# deferred remove delay is not reached: nothing should be removed
	echo "6-Performing HSM remove requests (before delay expiration)..."
	$RH -f ./cfg/$config_file --hsm-remove -l DEBUG -L rh_rm.log --once || error "hsm-remove"

	nb_rm=`grep "Remove request successful" rh_rm.log | wc -l`
	if (($nb_rm != 0)); then
		echo "********** test failed: no removal expected, $nb_rm done"
	else
		echo "OK: no rm done"
	fi

	echo "7-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	echo "8-Performing HSM remove requests (after delay expiration)..."
	$RH -f ./cfg/$config_file --hsm-remove -l DEBUG -L rh_rm.log --once || error ""

	nb_rm=`grep "Remove request successful" rh_rm.log | wc -l`
	if (($nb_rm != $expected_rm)); then
		error "********** TEST FAILED: $expected_rm removals expected, $nb_rm done"
	else
		echo "OK: $nb_rm files removed from archive"
	fi

	# kill event handler
	pkill -9 $PROC

}

function mass_softrm
{
	config_file=$1
	sleep_time=$2
	entries=$3
	policy_str="$4"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# populate filesystem
	echo "1-Populating filesystem..."
	for i in `seq 1 $entries`; do
		((dir_c=$i % 10))
		((subdir_c=$i % 100))
		dir=$ROOT/dir.$dir_c/subdir.$subdir_c
		mkdir -p $dir || error "creating directory $dir"
		echo "file.$i" > $dir/file.$i || error "creating file $dir/file.$i"
	done

	echo "2-Initial scan..."
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_scan.log || error "scanning filesystem"

	sleep 1

	# archiving files
	echo "3-Archiving files..."

	if (( $is_lhsm != 0 )); then
		flush_data
		$RH -f ./cfg/$config_file --sync -l DEBUG -L rh_migr.log || error "flushing data to backend"

		echo "3bis-Waiting for end of data migration..."
		wait_done 120 || error "Migration timeout"
	elif (( $is_hsmlite != 0 )); then
		$RH -f ./cfg/$config_file --sync -l DEBUG -L rh_migr.log || error "flushing data to backend"
	fi

	echo "Checking stats after 1st scan..."
	$REPORT -f ./cfg/$config_file --fs-info --csv -q > fsinfo.1
	$REPORT -f ./cfg/$config_file --deferred-rm --csv -q > deferred.1
	(( `wc -l fsinfo.1 | awk '{print $1}'` == 1 )) || error "a single file status is expected after data migration"
	status=`cat fsinfo.1 | cut -d "," -f 1 | tr -d ' '`
	nb=`cat fsinfo.1 | grep synchro | cut -d "," -f 2 | tr -d ' '`
	[[ -n $nb ]] || nb=0
	[[ "$status"=="synchro" ]] || error "status expected after data migration: synchro, got $status"
	(( $nb == $entries )) || error "$entries entries expected, got $nb"
	(( `wc -l deferred.1 | awk '{print $1}'`==0 )) || error "no deferred rm expected after first scan"
	rm -f fsinfo.1 deferred.1

	# removing some files
        echo "4-Removing files in $ROOT/dir.1..."
	rm -rf "$ROOT/dir.1" || error "removing files in $ROOT/dir.1"

	echo "5-Update DB with a new scan..."
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_scan.log || error "scanning filesystem"
	
	echo "Checking stats after 2nd scan..."
	$REPORT -f ./cfg/$config_file --fs-info --csv -q > fsinfo.2
	$REPORT -f ./cfg/$config_file --deferred-rm --csv -q > deferred.2
	# 100 files were in the removed directory
	(( `wc -l fsinfo.2 | awk '{print $1}'` == 1 )) || error "a single file status is expected after data migration"
	status=`cat fsinfo.2 | cut -d "," -f 1 | tr -d ' '`
	nb=`cat fsinfo.2 | grep synchro | cut -d "," -f 2 | tr -d ' '`
	[[ "$status"=="synchro" ]] || error "status expected after data migration: synchro, got $status"
	(( $nb == $entries - 100 )) || error "$entries - 100 entries expected, got $nb"
	nb=`wc -l deferred.2 | awk '{print $1}'`
	(( $nb == 100 )) || error "100 deferred rm expected after first scan, got $nb"
	rm -f fsinfo.2 deferred.2

}

function purge_test
{
	config_file=$1
	expected_purge=$2
	sleep_time=$3
	policy_str="$4"

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# initial scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log 

	# fill 10 files and archive them

	echo "1-Modifing files..."
	for i in a `seq 1 10`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=10 >/dev/null 2>/dev/null || error "writing file.$i"

		if (( $is_lhsm != 0 )); then
			flush_data
			lfs hsm_archive $ROOT/file.$i || error "lfs hsm_archive"
		fi
	done
	if (( $is_lhsm != 0 )); then
		wait_done 60 || error "Copy timeout"
	fi
	
	sleep 1
	if (( $no_log )); then
		echo "2-Scanning the FS again to update file status (after 1sec)..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "2-Reading changelogs to update file status (after 1sec)..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""

		if (($is_lhsm != 0)); then
			((`grep "archive,rc=0" rh_chglogs.log | wc -l` == 11)) || error "Not enough archive events in changelog!"
		fi
	fi

	echo "3-Applying purge policy ($policy_str)..."
	# no purge expected here
	$RH -f ./cfg/$config_file --purge-fs=0 -l DEBUG -L rh_purge.log --once || error ""

	if (( $is_lhsm != 0 )); then
	        nb_purge=`grep "Releasing" rh_purge.log | wc -l`
	else
	        nb_purge=`grep "Purged" rh_purge.log | wc -l`
	fi

        if (($nb_purge != 0)); then
                error "********** TEST FAILED: No release actions expected, $nb_purge done"
        else
                echo "OK: no file released"
        fi

	echo "4-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	echo "5-Applying purge policy again ($policy_str)..."
	$RH -f ./cfg/$config_file --purge-fs=0 -l DEBUG -L rh_purge.log --once || error ""

	if (( $is_lhsm != 0 )); then
	        nb_purge=`grep "Releasing" rh_purge.log | wc -l`
	else
	        nb_purge=`grep "Purged" rh_purge.log | wc -l`
	fi

        if (($nb_purge != $expected_purge)); then
                error "********** TEST FAILED: $expected_purge release actions expected, $nb_purge done"
        else
                echo "OK: $nb_purge files released"
        fi

	# stop RH in background
#	kill %1
}

function purge_size_filesets
{
	config_file=$1
	sleep_time=$2
	count=$3
	policy_str="$4"

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# initial scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log 

	# fill 3 files of different sizes and mark them archived non-dirty

	j=1
	for size in 0 1 10 200; do
		echo "1.$j-Writing files of size " $(( $size*10 )) "kB..."
		((j=$j+1))
		for i in `seq 1 $count`; do
			dd if=/dev/zero of=$ROOT/file.$size.$i bs=10k count=$size >/dev/null 2>/dev/null || error "writing file.$size.$i"

			if (( $is_lhsm != 0 )); then
				flush_data
				lfs hsm_archive $ROOT/file.$size.$i || error "lfs hsm_archive"
				wait_done 60 || error "Copy timeout"
			fi
		done
	done
	
	sleep 1
	if (( $no_log )); then
		echo "2-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "2-Reading changelogs to update file status (after 1sec)..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi


	echo "3-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	echo "4-Applying purge policy ($policy_str)..."
	# no purge expected here
	$RH -f ./cfg/$config_file --purge-fs=0 -l DEBUG -L rh_purge.log --once || error ""

	# counting each matching policy $count of each
	for policy in very_small mid_file default; do
	        nb_purge=`grep 'using policy' rh_purge.log | grep $policy | wc -l`
		if (($nb_purge != $count)); then
			error "********** TEST FAILED: $count release actions expected using policy $policy, $nb_purge done"
		else
			echo "OK: $nb_purge files released using policy $policy"
		fi
	done

	# stop RH in background
#	kill %1
}

function test_maint_mode
{
	config_file=$1
	window=$2 		# in seconds
	migr_policy_delay=$3  	# in seconds
	policy_str="$4"
	delay_min=$5  		# in seconds

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# writing data
	echo "1-Writing files..."
	for i in `seq 1 4`; do
		echo "file.$i" > $ROOT/file.$i || error "creating file $ROOT/file.$i"
	done
	t0=`date +%s`

	# read changelogs
	if (( $no_log )); then
		echo "2-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error "scanning filesystem"
	else
		echo "2-Reading changelogs..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error "reading changelogs"
	fi

    	# migrate (nothing must be migrated, no maint mode reported)
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error "executing --migrate action"
	grep "Maintenance time" rh_migr.log && error "No maintenance mode expected"
	grep "Currently in maintenance mode" rh_migr.log && error "No maintenance mode expected"

	# set maintenance mode (due is window +10s)
	maint_time=`perl -e "use POSIX; print strftime(\"%Y%m%d%H%M%S\" ,localtime($t0 + $window + 10))"`
	$REPORT -f ./cfg/$config_file --next-maintenance=$maint_time || error "setting maintenance time"

	# right now, migration window is in the future
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error "executing --migrate action"
	grep "maintenance window will start in" rh_migr.log || errot "Future maintenance not report in the log"

	# sleep enough to be in the maintenance window
	sleep 11

	# split maintenance window in 4
	((delta=$window / 4))
	(( $delta == 0 )) && delta=1

	arch_done=0

	# start migrations while we do not reach maintenance time
	while (( `date +%s` < $t0 + $window + 10 )); do
		cp /dev/null rh_migr.log
		$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error "executing --migrate action"
		grep "Currently in maintenance mode" rh_migr.log || error "Should be in maintenance window now"

		# check that files are migrated after min_delay and before the policy delay
		if grep "$ARCH_STR" rh_migr.log ; then
			arch_done=1
			now=`date +%s`
			# delay_min must be enlapsed
			(( $now >= $t0 + $delay_min )) || error "file migrated before dealy min"
			# migr_policy_delay must not been reached
			(( $now < $t0 + $migr_policy_delay )) || error "file already reached policy delay"
		fi
		sleep $delta
	done
	cp /dev/null rh_migr.log

	(($arch_done == 1)) || error "Files have not been migrated during maintenance window"

	(( `date +%s` > $t0 + $window + 15 )) || sleep $(( $t0 + $window + 15 - `date +%s` ))
	# shouldn't be in maintenance now
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error "executing --migrate action"
	grep "Maintenance time is in the past" rh_migr.log || error "Maintenance window should be in the past now"
}

# test reporting function with path filter
function test_rh_report
{
	config_file=$1
	dircount=$2
	sleep_time=$3
	descr_str="$4"

	clean_logs

	for i in `seq 1 $dircount`; do
		mkdir $ROOT/dir.$i
		echo "1.$i-Writing files to $ROOT/dir.$i..."
		# write i MB to each directory
		for j in `seq 1 $i`; do
			dd if=/dev/zero of=$ROOT/dir.$i/file.$j bs=1M count=1 >/dev/null 2>/dev/null || error "writing $ROOT/dir.$i/file.$j"
		done
	done

	echo "1bis. Wait for IO completion..."
	sync

	if (( $no_log )); then
		echo "2-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "2-Reading changelogs..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi

	echo "3.Checking reports..."
	for i in `seq 1 $dircount`; do
		$REPORT -f ./cfg/$config_file -l MAJOR --csv -U 1 -P "$ROOT/dir.$i/*" > rh_report.log
		used=`tail -n 1 rh_report.log | cut -d "," -f 3`
		if (( $used != $i*1024*1024 )); then
			error ": $used != " $(($i*1024*1024))
		else
			echo "OK: $i MB in $ROOT/dir.$i"
		fi
	done
	
}

#test report using accounting table
function test_rh_acct_report
{
        config_file=$1
        dircount=$2
        descr_str="$3"

        clean_logs

        for i in `seq 1 $dircount`; do
                mkdir $ROOT/dir.$i
                echo "1.$i-Writing files to $ROOT/dir.$i..."
                # write i MB to each directory
                for j in `seq 1 $i`; do
                        dd if=/dev/zero of=$ROOT/dir.$i/file.$j bs=1M count=1 >/dev/null 2>/dev/null || error "writing $ROOT/dir.$i/file.$j"
                done
        done

        echo "1bis. Wait for IO completion..."
        sync

        echo "2-Scanning..."
        $RH -f ./cfg/$config_file --scan -l DEBUG -L rh_scan.log  --once || error "scanning filesystem"

        echo "3.Checking reports..."
        $REPORT -f ./cfg/$config_file -l MAJOR --csv --force-no-acct --top-user > rh_no_acct_report.log
        $REPORT -f ./cfg/$config_file -l MAJOR --csv --top-user > rh_acct_report.log

        nbrowacct=` awk -F ',' 'END {print NF}' rh_acct_report.log`;
        nbrownoacct=` awk -F ',' 'END {print NF}' rh_no_acct_report.log`;
        for i in `seq 1 $nbrowacct`; do
                rowchecked=0;
                for j in `seq 1 $nbrownoacct`; do
                        if [[ `cut -d "," -f $i rh_acct_report.log` == `cut -d "," -f $j rh_no_acct_report.log`  ]]; then
                                rowchecked=1
                                break
                        fi
                done
                if (( $rowchecked == 1 )); then
                        echo "Row `awk -F ',' 'NR == 1 {print $'$i';}' rh_acct_report.log | tr -d ' '` OK"
                else
                        error "Row `awk -F ',' 'NR == 1 {print $'$i';}' rh_acct_report.log | tr -d ' '` is different with acct "
                fi
        done
        rm -f rh_no_acct_report.log
        rm -f rh_acct_report.log
}

#test --split-user-groups option
function test_rh_report_split_user_group
{
        config_file=$1
        dircount=$2
        option=$3
        descr_str="$4"

        clean_logs

        for i in `seq 1 $dircount`; do
                mkdir $ROOT/dir.$i
                echo "1.$i-Writing files to $ROOT/dir.$i..."
                # write i MB to each directory
                for j in `seq 1 $i`; do
                        dd if=/dev/zero of=$ROOT/dir.$i/file.$j bs=1M count=1 >/dev/null 2>/dev/null || error "writing $ROOT/dir.$i/file.$j"
                done
        done

        echo "1bis. Wait for IO completion..."
        sync

        echo "2-Scanning..."
        $RH -f ./cfg/$config_file --scan -l DEBUG -L rh_scan.log  --once || error "scanning filesystem"

        echo "3.Checking reports..."
        $REPORT -f ./cfg/$config_file -l MAJOR --csv --user-info $option | head --lines=-2 > rh_report_no_split.log
        $REPORT -f ./cfg/$config_file -l MAJOR --csv --user-info --split-user-groups $option | head --lines=-2 > rh_report_split.log

        nbrow=` awk -F ',' 'END {print NF}' rh_report_split.log`
        nb_uniq_user=`sed "1d" rh_report_split.log | cut -d "," -f 1 | uniq | wc -l `
        for i in `seq 1 $nb_uniq_user`; do
                check=1
                user=`sed "1d" rh_report_split.log | awk -F ',' '{print $1;}' | uniq | awk 'NR=='$i'{ print }'`
                for j in `seq 1 $nbrow`; do
                        curr_row=`sed "1d" rh_report_split.log | awk -F ',' 'NR==1 { print $'$j'; }' | tr -d ' '`
                        curr_row_label=` awk -F ',' 'NR==1 { print $'$j'; }' rh_report_split.log | tr -d ' '`
                        if [[ "$curr_row" =~ "^[0-9]*$" && "$curr_row_label" != "avg_size" ]]; then
				if [[ `grep -e "dir" rh_report_split.log` ]]; then
					sum_split_dir=`egrep -e "^$user.*dir.*" rh_report_split.log | awk -F ',' '{array[$1]+=$'$j'}END{for (name in array) {print array[name]}}'`
					sum_no_split_dir=`egrep -e "^$user.*dir.*" rh_report_no_split.log | awk -F ',' '{array[$1]+=$'$((j-1))'}END{for (name in array) {print array[name]}}'`
					sum_split_file=`egrep -e "^$user.*file.*" rh_report_split.log | awk -F ',' '{array[$1]+=$'$j'}END{for (name in array) {print array[name]}}'`
					sum_no_split_file=`egrep -e "^$user.*file.*" rh_report_no_split.log | awk -F ',' '{array[$1]+=$'$((j-1))'}END{for (name in array) {print array[name]}}'`
                                        if (( $sum_split_dir != $sum_no_split_dir || $sum_split_file != $sum_no_split_file )); then
                                                check=0
                                        fi
				else
                                        sum_split=`egrep -e "^$user" rh_report_split.log | awk -F ',' '{array[$1]+=$'$j'}END{for (name in array) {print array[name]}}'`
                                        sum_no_split=`egrep -e "^$user" rh_report_no_split.log | awk -F ',' '{array[$1]+=$'$((j-1))'}END{for (name in array) {print array[name]}}'`
					if (( $sum_split != $sum_no_split )); then
                                        	check=0
                                	fi
				fi
                        fi
                done
                if (( $check == 1 )); then
                        echo "Report for user $user: OK"
                else
                        error "Report for user $user is wrong"
                fi
        done

        rm -f rh_report_no_split.log
        rm -f rh_report_split.log

}

#test acct table and triggers creation
function test_acct_table
{
        config_file=$1
        dircount=$2
        descr_str="$3"

        clean_logs
	
        for i in `seq 1 $dircount`; do
	        mkdir $ROOT/dir.$i
                echo "1.$i-Writing files to $ROOT/dir.$i..."
                # write i MB to each directory
                for j in `seq 1 $i`; do
                        dd if=/dev/zero of=$ROOT/dir.$i/file.$j bs=1M count=1 >/dev/null 2>/dev/null || error "writing $ROOT/dir.$i/file.$j"
                done
        done

        echo "1bis. Wait for IO completion..."
        sync

        echo "2-Scanning..."
        $RH -f ./cfg/$config_file --scan -l VERB -L rh_scan.log  --once || error "scanning filesystem"

        echo "3.Checking acct table and triggers creation"
        grep -q "Table ACCT_STAT created sucessfully" rh_scan.log && echo "ACCT table creation: OK" || error "creating ACCT table"
        grep -q "Trigger ACCT_ENTRY_INSERT created sucessfully" rh_scan.log && echo "ACCT_ENTRY_INSERT trigger creation: OK" || error "creating ACCT_ENTRY_INSERT trigger"
        grep -q "Trigger ACCT_ENTRY_UPDATE created sucessfully" rh_scan.log && echo "ACCT_ENTRY_INSERT trigger creation: OK" || error "creating ACCT_ENTRY_UPDATE trigger"
        grep -q "Trigger ACCT_ENTRY_DELETE created sucessfully" rh_scan.log && echo "ACCT_ENTRY_INSERT trigger creation: OK" || error "creating ACCT_ENTRY_DELETE trigger"

}

function path_test
{
	config_file=$1
	sleep_time=$2
	policy_str="$3"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "hsm test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# create test tree

	mkdir -p $ROOT/dir1
	mkdir -p $ROOT/dir1/subdir1
	mkdir -p $ROOT/dir1/subdir2
	mkdir -p $ROOT/dir1/subdir3/subdir4
	# 2 matching files for fileclass absolute_path
	echo "data" > $ROOT/dir1/subdir1/A
	echo "data" > $ROOT/dir1/subdir2/A
	# 2 unmatching
	echo "data" > $ROOT/dir1/A
	echo "data" > $ROOT/dir1/subdir3/subdir4/A

	mkdir -p $ROOT/dir2
	mkdir -p $ROOT/dir2/subdir1
	# 2 matching files for fileclass absolute_tree
	echo "data" > $ROOT/dir2/X
	echo "data" > $ROOT/dir2/subdir1/X

	mkdir -p $ROOT/one_dir/dir3
	mkdir -p $ROOT/other_dir/dir3
	mkdir -p $ROOT/dir3
	mkdir -p $ROOT/one_dir/one_dir/dir3
	# 2 matching files for fileclass path_depth2
	echo "data" > $ROOT/one_dir/dir3/X
	echo "data" > $ROOT/other_dir/dir3/Y
	# 2 unmatching files for fileclass path_depth2
	echo "data" > $ROOT/dir3/X
	echo "data" > $ROOT/one_dir/one_dir/dir3/X

	mkdir -p $ROOT/one_dir/dir4/subdir1
	mkdir -p $ROOT/other_dir/dir4/subdir1
	mkdir -p $ROOT/dir4
	mkdir -p $ROOT/one_dir/one_dir/dir4
	# 2 matching files for fileclass tree_depth2
	echo "data" > $ROOT/one_dir/dir4/subdir1/X
	echo "data" > $ROOT/other_dir/dir4/subdir1/X
	# unmatching files for fileclass tree_depth2
	echo "data" > $ROOT/dir4/X
	echo "data" > $ROOT/one_dir/one_dir/dir4/X
	
	mkdir -p $ROOT/dir5
	mkdir -p $ROOT/subdir/dir5
	# 2 matching files for fileclass relative_path
	echo "data" > $ROOT/dir5/A
	echo "data" > $ROOT/dir5/B
	# 2 unmatching files for fileclass relative_path
	echo "data" > $ROOT/subdir/dir5/A
	echo "data" > $ROOT/subdir/dir5/B

	mkdir -p $ROOT/dir6/subdir
	mkdir -p $ROOT/subdir/dir6
	# 2 matching files for fileclass relative_tree
	echo "data" > $ROOT/dir6/A
	echo "data" > $ROOT/dir6/subdir/A
	# 2 unmatching files for fileclass relative_tree
	echo "data" > $ROOT/subdir/dir6/A
	echo "data" > $ROOT/subdir/dir6/B


	mkdir -p $ROOT/dir7/subdir
	mkdir -p $ROOT/dir71/subdir
	mkdir -p $ROOT/subdir/subdir/dir7
	mkdir -p $ROOT/subdir/subdir/dir72
	# 2 matching files for fileclass any_root_tree
	echo "data" > $ROOT/dir7/subdir/file
	echo "data" > $ROOT/subdir/subdir/dir7/file
	# 2 unmatching files for fileclass any_root_tree
	echo "data" > $ROOT/dir71/subdir/file
	echo "data" > $ROOT/subdir/subdir/dir72/file

	mkdir -p $ROOT/dir8
	mkdir -p $ROOT/dir81/subdir
	mkdir -p $ROOT/subdir/subdir/dir8
	# 2 matching files for fileclass any_root_path
	echo "data" > $ROOT/dir8/file.1
	echo "data" > $ROOT/subdir/subdir/dir8/file.1
	# 3 unmatching files for fileclass any_root_path
	echo "data" > $ROOT/dir8/file.2
	echo "data" > $ROOT/dir81/file.1
	echo "data" > $ROOT/subdir/subdir/dir8/file.2

	mkdir -p $ROOT/dir9/subdir/dir10/subdir
	mkdir -p $ROOT/dir9/subdir/dir10x/subdir
	mkdir -p $ROOT/dir91/subdir/dir10
	# 2 matching files for fileclass any_level_tree
	echo "data" > $ROOT/dir9/subdir/dir10/file
	echo "data" > $ROOT/dir9/subdir/dir10/subdir/file
	# 2 unmatching files for fileclass any_level_tree
	echo "data" > $ROOT/dir9/subdir/dir10x/subdir/file
	echo "data" > $ROOT/dir91/subdir/dir10/file

	mkdir -p $ROOT/dir11/subdir/subdir
	mkdir -p $ROOT/dir11x/subdir
	# 2 matching files for fileclass any_level_path
	echo "data" > $ROOT/dir11/subdir/file
	echo "data" > $ROOT/dir11/subdir/subdir/file
	# 2 unmatching files for fileclass any_level_path
	echo "data" > $ROOT/dir11/subdir/file.x
	echo "data" > $ROOT/dir11x/subdir/file


	echo "1bis-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	# read changelogs
	if (( $no_log )); then
		echo "2-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "2-Reading changelogs..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi


	echo "3-Applying migration policy ($policy_str)..."
	# start a migration files should notbe migrated this time
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error ""

	# count the number of file for each policy
	nb_pol1=`grep hints rh_migr.log | grep absolute_path | wc -l`
	nb_pol2=`grep hints rh_migr.log | grep absolute_tree | wc -l`
	nb_pol3=`grep hints rh_migr.log | grep path_depth2 | wc -l`
	nb_pol4=`grep hints rh_migr.log | grep tree_depth2 | wc -l`
	nb_pol5=`grep hints rh_migr.log | grep relative_path | wc -l`
	nb_pol6=`grep hints rh_migr.log | grep relative_tree | wc -l`

	nb_pol7=`grep hints rh_migr.log | grep any_root_tree | wc -l`
	nb_pol8=`grep hints rh_migr.log | grep any_root_path | wc -l`
	nb_pol9=`grep hints rh_migr.log | grep any_level_tree | wc -l`
	nb_pol10=`grep hints rh_migr.log | grep any_level_path | wc -l`

	nb_unmatch=`grep hints rh_migr.log | grep unmatch | wc -l`

	(( $nb_pol1 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'absolute_path': $nb_pol1"
	(( $nb_pol2 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'absolute_tree': $nb_pol2"
	(( $nb_pol3 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'path_depth2': $nb_pol3"
	(( $nb_pol4 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'tree_depth2': $nb_pol4"
	(( $nb_pol5 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'relative_path': $nb_pol5"
	(( $nb_pol6 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'relative_tree': $nb_pol6"

	(( $nb_pol7 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'any_root_tree': $nb_pol7"
	(( $nb_pol8 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'any_root_path': $nb_pol8"
	(( $nb_pol9 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'any_level_tree': $nb_pol9"
	(( $nb_pol10 == 2 )) || error "********** TEST FAILED: wrong count of matching files for policy 'any_level_tree': $nb_pol10"
	(( $nb_unmatch == 19 )) || error "********** TEST FAILED: wrong count of unmatching files: $nb_unmatch"

	(( $nb_pol1 == 2 )) && (( $nb_pol2 == 2 )) && (( $nb_pol3 == 2 )) && (( $nb_pol4 == 2 )) \
        	&& (( $nb_pol5 == 2 )) && (( $nb_pol6 == 2 )) && (( $nb_pol7 == 2 )) \
		&& (( $nb_pol8 == 2 )) && (( $nb_pol9 == 2 )) && (( $nb_pol10 == 2 )) \
		&& (( $nb_unmatch == 19 )) \
		&& echo "OK: test successful"
}

function update_test
{
	config_file=$1
	event_updt_min=$2
	update_period=$3
	policy_str="$4"

	init=`date "+%s"`

	LOG=rh_chglogs.log

	if (( $no_log )); then
		echo "changelog disabled: skipped"
		set_skipped
		return 1
	fi

	for i in `seq 1 3`; do
		t=$(( `date "+%s"` - $init ))
		echo "loop 1.$i: many 'touch' within $event_updt_min sec (t=$t)"
		clean_logs

		# start log reader (DEBUG level displays needed attrs)
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L $LOG --detach --pid-file=rh.pid || error ""

		start=`date "+%s"`
		# generate a lot of TIME events within 'event_updt_min'
		# => must only update once
		while (( `date "+%s"` - $start < $event_updt_min - 2 )); do
			touch $ROOT/file
			usleep 10000
		done

		# force flushing log
		sleep 1
		pkill $PROC
		sleep 1
		t=$(( `date "+%s"` - $init ))

		nb_getattr=`grep getattr=1 $LOG | wc -l`
		egrep -e "getattr=1|needed because" $LOG
		echo "nb attr update: $nb_getattr"
		(( $nb_getattr == 1 )) || error "********** TEST FAILED: wrong count of getattr: $nb_getattr (t=$t)"
		# the path may be retrieved at the first loop (at creation)
		# but not during the next loop (as long as enlapsed time < update_period)
		if (( $i > 1 )) && (( `date "+%s"` - $init < $update_period )); then
			nb_getpath=`grep getpath=1 $LOG | wc -l`
			grep "getpath=1" $LOG
			echo "nb path update: $nb_getpath"
			(( $nb_getpath == 0 )) || error "********** TEST FAILED: wrong count of getpath: $nb_getpath (t=$t)"
		fi

		# wait for 5s to be fully enlapsed
		while (( `date "+%s"` - $start <= $event_updt_min )); do
			usleep 100000
		done
	done

	init=`date "+%s"`

	for i in `seq 1 3`; do
		echo "loop 2.$i: many 'rename' within $event_updt_min sec"
		clean_logs

		# start log reader (DEBUG level displays needed attrs)
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L $LOG --detach --pid-file=rh.pid || error ""

		start=`date "+%s"`
		# generate a lot of TIME events within 'event_updt_min'
		# => must only update once
		while (( `date "+%s"` - $start < $event_updt_min - 2 )); do
			mv $ROOT/file $ROOT/file.2
			usleep 10000
			mv $ROOT/file.2 $ROOT/file
			usleep 10000
		done

		# force flushing log
		sleep 1
		pkill $PROC
		sleep 1

		nb_getpath=`grep getpath=1 $LOG | wc -l`
		echo "nb path update: $nb_getpath"
		(( $nb_getpath == 1 )) || error "********** TEST FAILED: wrong count of getpath: $nb_getpath"

		# attributes may be retrieved at the first loop (at creation)
		# but not during the next loop (as long as enlapsed time < update_period)
		if (( $i > 1 )) && (( `date "+%s"` - $init < $update_period )); then
			nb_getattr=`grep getattr=1 $LOG | wc -l`
			echo "nb attr update: $nb_getattr"
			(( $nb_getattr == 0 )) || error "********** TEST FAILED: wrong count of getattr: $nb_getattr"
		fi
	done

	echo "Waiting $update_period seconds..."
	clean_logs

	# check that getattr+getpath are performed after update_period, even if the event is not related:
	$RH -f ./cfg/$config_file --readlog -l DEBUG -L $LOG --detach --pid-file=rh.pid || error ""
	sleep $update_period

	if (( $is_lhsm != 0 )); then
		# chg something different that path or POSIX attributes
		lfs hsm_set --noarchive $ROOT/file
	else
		touch $ROOT/file
	fi

	# force flushing log
	sleep 1
	pkill $PROC
	sleep 1

	nb_getattr=`grep getattr=1 $LOG | wc -l`
	echo "nb attr update: $nb_getattr"
	(( $nb_getattr == 1 )) || error "********** TEST FAILED: wrong count of getattr: $nb_getattr"
	nb_getpath=`grep getpath=1 $LOG | wc -l`
	echo "nb path update: $nb_getpath"
	(( $nb_getpath == 1 )) || error "********** TEST FAILED: wrong count of getpath: $nb_getpath"

	if (( $is_lhsm != 0 )); then
		# also check that the status is to be retrieved
		nb_getstatus=`grep getstatus=1 $LOG | wc -l`
		echo "nb status update: $nb_getstatus"
		(( $nb_getstatus == 1 )) || error "********** TEST FAILED: wrong count of getstatus: $nb_getstatus"
	fi

	# kill remaning event handler
	sleep 1
	pkill -9 $PROC
}

function periodic_class_match_migr
{
	config_file=$1
	update_period=$2
	policy_str="$3"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	#create test tree
	touch $ROOT/ignore1
	touch $ROOT/whitelist1
	touch $ROOT/migrate1
	touch $ROOT/default1

	# scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log

	# now apply policies
	$RH -f ./cfg/$config_file --migrate --dry-run -l FULL -L rh_migr.log --once || error ""

	#we must have 4 lines like this: "Need to update fileclass (not set)"
	nb_updt=`grep "Need to update fileclass (not set)" rh_migr.log | wc -l`
	nb_migr_match=`grep "matches the condition for policy 'migr_match'" rh_migr.log | wc -l`
	nb_default=`grep "matches the condition for policy 'default'" rh_migr.log | wc -l`

	(( $nb_updt == 4 )) || error "********** TEST FAILED: wrong count of fileclass update: $nb_updt"
	(( $nb_migr_match == 1 )) || error "********** TEST FAILED: wrong count of files matching 'migr_match': $nb_migr_match"
	(( $nb_default == 1 )) || error "********** TEST FAILED: wrong count of files matching 'default': $nb_default"

        (( $nb_updt == 4 )) && (( $nb_migr_match == 1 )) && (( $nb_default == 1 )) \
		&& echo "OK: initial fileclass matching successful"

	# rematch entries: should not update fileclasses
	clean_logs
	$RH -f ./cfg/$config_file --migrate --dry-run -l FULL -L rh_migr.log --once || error ""

	nb_default_valid=`grep "fileclass '@default@' is still valid" rh_migr.log | wc -l`
	nb_migr_valid=`grep "fileclass 'to_be_migr' is still valid" rh_migr.log | wc -l`
	nb_updt=`grep "Need to update fileclass" rh_migr.log | wc -l`

	(( $nb_default_valid == 1 )) || error "********** TEST FAILED: wrong count of cached fileclass for default policy: $nb_default_valid"
	(( $nb_migr_valid == 1 )) || error "********** TEST FAILED: wrong count of cached fileclass for 'migr_match' : $nb_migr_valid"
	(( $nb_updt == 0 )) || error "********** TEST FAILED: no expected fileclass update: $nb_updt updated"

        (( $nb_updt == 0 )) && (( $nb_default_valid == 1 )) && (( $nb_migr_valid == 1 )) \
		&& echo "OK: fileclasses do not need update"
	
	echo "Waiting $update_period sec..."
	sleep $update_period

	# rematch entries: should update all fileclasses
	clean_logs
	$RH -f ./cfg/$config_file --migrate --dry-run -l FULL -L rh_migr.log --once || error ""

	nb_valid=`grep "is still valid" rh_migr.log | wc -l`
	nb_updt=`grep "Need to update fileclass (out-of-date)" rh_migr.log | wc -l`

	(( $nb_valid == 0 )) || error "********** TEST FAILED: fileclass should need update : $nb_valid still valid"
	(( $nb_updt == 4 )) || error "********** TEST FAILED: all fileclasses should be updated : $nb_updt/4"

        (( $nb_valid == 0 )) && (( $nb_updt == 4 )) \
		&& echo "OK: all fileclasses updated"
}

function periodic_class_match_purge
{
	config_file=$1
	update_period=$2
	policy_str="$3"

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi
	clean_logs

	echo "Writing and archiving files..."
	#create test tree of archived files
	for file in ignore1 whitelist1 purge1 default1 ; do
		touch $ROOT/$file

		if (( $is_lhsm != 0 )); then
			flush_data
			lfs hsm_archive $ROOT/$file
		fi
	done
	if (( $is_lhsm != 0 )); then
		wait_done 60 || error "Copy timeout"
	fi

	echo "FS Scan..."
	# scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log

	# now apply policies
	$RH -f ./cfg/$config_file --purge-fs=0 --dry-run -l FULL -L rh_purge.log --once || error ""

	# HSM: we must have 4 lines like this: "Need to update fileclass (not set)"
	# TMP_FS_MGR:  whitelisted status is always checked at scan time
	# 	so 2 entries have already been matched (ignore1 and whitelist1)
	if (( $is_lhsm == 0 )); then
		already=2
	else
		already=0
	fi

	nb_updt=`grep "Need to update fileclass (not set)" rh_purge.log | wc -l`
	nb_purge_match=`grep "matches the condition for policy 'purge_match'" rh_purge.log | wc -l`
	nb_default=`grep "matches the condition for policy 'default'" rh_purge.log | wc -l`

	(( $nb_updt == 4 - $already )) || error "********** TEST FAILED: wrong count of fileclass update: $nb_updt"
	(( $nb_purge_match == 1 )) || error "********** TEST FAILED: wrong count of files matching 'purge_match': $nb_purge_match"
	(( $nb_default == 1 )) || error "********** TEST FAILED: wrong count of files matching 'default': $nb_default"

        (( $nb_updt == 4 - $already )) && (( $nb_purge_match == 1 )) && (( $nb_default == 1 )) \
		&& echo "OK: initial fileclass matching successful"

	# TMP_FS_MGR:  whitelisted status is always checked at scan time
	# 	2 entries are new (default and to_be_released)
	if (( $is_lhsm == 0 )); then
		already=0
		new=2
	else
		already=0
		new=0
	fi

	# update db content and rematch entries: should update all fileclasses
	clean_logs
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log

	echo "Waiting $update_period sec..."
	sleep $update_period

	$RH -f ./cfg/$config_file --purge-fs=0 --dry-run -l FULL -L rh_purge.log --once || error ""

	nb_valid=`grep "is still valid" rh_purge.log | wc -l`
	nb_updt=`grep "Need to update fileclass (out-of-date)" rh_purge.log | wc -l`
	nb_not_set=`grep "Need to update fileclass (not set)" rh_purge.log | wc -l`

	(( $nb_valid == $already )) || error "********** TEST FAILED: fileclass should need update : $nb_valid still valid"
	(( $nb_updt == 4 - $already - $new )) || error "********** TEST FAILED: wrong number of fileclasses should be updated : $nb_updt"
	(( $nb_not_set == $new )) || error "********** TEST FAILED:  wrong number of fileclasse fileclasses should be matched : $nb_not_set"

        (( $nb_valid == $already )) && (( $nb_updt == 4 - $already - $new )) \
		&& echo "OK: fileclasses correctly updated"
}

function test_cnt_trigger
{
	config_file=$1
	file_count=$2
	exp_purge_count=$3
	policy_str="$4"

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi
	clean_logs

	# initial inode count
	empty_count=`df -i $ROOT/ | grep "$ROOT" | awk '{print $(NF-3)}'`
	(( file_count=$file_count - $empty_count ))

	#create test tree of archived files (1M each)
	for i in `seq 1 $file_count`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=1 >/dev/null 2>/dev/null || error "writting $ROOT/file.$i"

		if (( $is_lhsm != 0 )); then
			lfs hsm_archive $ROOT/file.$i
		fi
	done

	if (( $is_lhsm != 0 )); then
		wait_done 60 || error "Copy timeout"
	fi

	# wait for df sync
	sync; sleep 1

	# scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log

	# apply purge trigger
	$RH -f ./cfg/$config_file --purge --once -l FULL -L rh_purge.log

	if (($is_lhsm != 0 )); then
		nb_release=`grep "Released" rh_purge.log | wc -l`
	else
		nb_release=`grep "Purged" rh_purge.log | wc -l`
	fi

	if (($nb_release == $exp_purge_count)); then
		echo "OK: $nb_release files released"
	else
		error ": $nb_release files released, $exp_purge_count expected"
	fi
}


function test_ost_trigger
{
	config_file=$1
	mb_h_threshold=$2
	mb_l_threshold=$3
	policy_str="$4"

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi
	clean_logs

	empty_vol=`lfs df  | grep OST0000 | awk '{print $3}'`
	empty_vol=$(($empty_vol/1024))

	lfs setstripe --count 2 --offset 0 $ROOT || error "setting stripe_count=2"

	#create test tree of archived files (2M each=1MB/ost) until we reach high threshold
	((count=$mb_h_threshold - $empty_vol + 1))
	for i in `seq $empty_vol $mb_h_threshold`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=2  >/dev/null 2>/dev/null || error "writting $ROOT/file.$i"

		if (( $is_lhsm != 0 )); then
			flush_data
			lfs hsm_archive $ROOT/file.$i
		fi
	done
	if (( $is_lhsm != 0 )); then
		wait_done 60 || error "Copy timeout"
	fi

	# wait for df sync
	sync; sleep 1

	if (( $is_lhsm != 0 )); then
		arch_count=`lfs hsm_state $ROOT/file.* | grep "exists archived" | wc -l`
		(( $arch_count == $count )) || error "File count $count != archived count $arch_count"
	fi

	full_vol=`lfs df  | grep OST0000 | awk '{print $3}'`
	full_vol=$(($full_vol/1024))
	delta=$(($full_vol-$empty_vol))
	echo "OST#0 usage increased of $delta MB (total usage = $full_vol MB)"
	((need_purge=$full_vol-$mb_l_threshold))
	echo "Need to purge $need_purge MB on OST#0"

	# scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log

	$REPORT -f ./cfg/$config_file -i

	# apply purge trigger
	$RH -f ./cfg/$config_file --purge --once -l DEBUG -L rh_purge.log

	grep summary rh_purge.log
	stat_purge=`grep summary rh_purge.log | grep "OST #0" | awk '{print $(NF-9)" "$(NF-3)" "$(NF-2)}' | sed -e "s/[^0-9 ]//g"`

	purged_ost=`echo $stat_purge | awk '{print $1}'`
	purged_total=`echo $stat_purge | awk '{print $2}'`
	needed_ost=`echo $stat_purge | awk '{print $3}'`

	# change blocks to MB (*512/1024/1024 == /2048)
	((purged_ost=$purged_ost/2048))
	((purged_total=$purged_total/2048))
	((needed_ost=$needed_ost/2048))

	# checks
	# - needed_ost must be equal to the amount we computed (need_purge)
	# - purged_ost must be over the amount we computed and under need_purge+1MB
	# - purged_total must be twice purged_ost
	(( $needed_ost == $need_purge )) || error ": invalid amount of data computed ($needed_ost != $need_purge)"
	(( $purged_ost >= $need_purge )) && (( $purged_ost <= $need_purge + 1 )) || error ": invalid amount of data purged ($purged_ost < $need_purge)"
	(( $purged_total == 2*$purged_ost )) || error ": invalid total volume purged ($purged_total != 2*$purged_ost)"

	(( $needed_ost == $need_purge )) && (( $purged_ost >= $need_purge )) && (( $purged_ost <= $need_purge + 1 )) \
		&& (( $purged_total == 2*$purged_ost )) && echo "OK: purge of OST#0 succeeded"

	full_vol1=`lfs df  | grep OST0001 | awk '{print $3}'`
	full_vol1=$(($full_vol1/1024))
	purge_ost1=`grep summary rh_purge.log | grep "OST #1" | wc -l`

	if (($full_vol1 > $mb_h_threshold )); then
		error ": OST#1 is not expected to exceed high threshold!"
	elif (($purge_ost1 != 0)); then
		error ": no purge expected on OST#1"
	else
		echo "OK: no purge on OST#1 (usage=$full_vol1 MB)"
	fi
}

function test_trigger_check
{
	config_file=$1
	max_count=$2
	max_vol_mb=$3
	policy_str="$4"
	target_count=$5
	target_fs_vol=$6
	target_user_vol=$7
	max_user_vol=$8

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi
	clean_logs

	# triggers to be checked
	# - inode count > max_count
	# - fs volume	> max_vol
	# - root quota  > user_quota

	# initial inode count
	empty_count=`df -i $ROOT/ | xargs | awk '{print $(NF-3)}'`
	((file_count=$max_count-$empty_count))

	# compute file size to exceed max vol and user quota
	empty_vol=`df -k $ROOT  | xargs | awk '{print $(NF-3)}'`
	((empty_vol=$empty_vol/1024))

	if (( $empty_vol < $max_vol_mb )); then
		((missing_mb=$max_vol_mb-$empty_vol))
	else
		missing_mb=0
	fi
	
	if (($missing_mb < $max_user_vol )); then
		missing_mb=$max_user_vol
	fi

	# file_size = missing_mb/file_count + 1
	((file_size=$missing_mb/$file_count + 1 ))

	echo "$file_count files missing, $file_size MB each"

	#create test tree of archived files (file_size MB each)
	for i in `seq 1 $file_count`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=$file_size  >/dev/null 2>/dev/null || error "writting $ROOT/file.$i"

		if (( $is_lhsm != 0 )); then
			flush_data
			lfs hsm_archive $ROOT/file.$i
		fi
	done

	if (( $is_lhsm != 0 )); then
		wait_done 60 || error "Copy timeout"
	fi

	# wait for df sync
	sync; sleep 1

	# scan
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_chglogs.log

	$REPORT -f ./cfg/$config_file -i

	# check purge triggers
	$RH -f ./cfg/$config_file --check-thresholds --once -l FULL -L rh_purge.log

	((expect_count=$empty_count+$file_count-$target_count))
	((expect_vol_fs=$empty_vol+$file_count*$file_size-$target_fs_vol))
	((expect_vol_user=$file_count*$file_size-$target_user_vol))
	echo "over trigger limits: $expect_count entries, $expect_vol_fs MB, $expect_vol_user MB for user root"

	if (($is_lhsm != 0 )); then
		nb_release=`grep "Released" rh_purge.log | wc -l`
	else
		nb_release=`grep "Purged" rh_purge.log | wc -l`
	fi

	count_trig=`grep " entries must be purged in Filesystem" rh_purge.log | cut -d '|' -f 2 | awk '{print $1}'`

	vol_fs_trig=`grep " blocks (x512) must be purged on Filesystem" rh_purge.log | cut -d '|' -f 2 | awk '{print $1}'`
	((vol_fs_trig_mb=$vol_fs_trig/2048)) # /2048 == *512/1024/1024

	vol_user_trig=`grep " blocks (x512) must be purged for user" rh_purge.log | cut -d '|' -f 2 | awk '{print $1}'`
	((vol_user_trig_mb=$vol_user_trig/2048)) # /2048 == *512/1024/1024
	
	echo "triggers reported: $count_trig entries, $vol_fs_trig_mb MB, $vol_user_trig_mb MB"

	# check then was no actual purge
	if (($nb_release > 0)); then
		error ": $nb_release files released, no purge expected"
	elif (( $count_trig != $expect_count )); then
		error ": trigger reported $count_trig files over threshold, $expect_count expected"
	elif (( $vol_fs_trig_mb != $expect_vol_fs )); then
		error ": trigger reported $vol_fs_trig_mb MB over threshold, $expect_vol_fs expected"
	elif (( $vol_user_trig_mb != $expect_vol_user )); then
		error ": trigger reported $vol_user_trig_mb MB over threshold, $expect_vol_user expected"
	else
		echo "OK: all checks successful"
	fi
}

function check_released
{
	if (($is_lhsm != 0)); then
		lfs hsm_state $1 | grep released || return 1
	else
		[ -f $1 ] && return 1
	fi
	return 0
}

function test_periodic_trigger
{
	config_file=$1
	sleep_time=$2
	policy_str=$3

	if (( ($is_hsmlite != 0) && ($shook == 0) )); then
		echo "No purge for hsmlite purpose (shook=$shook): skipped"
		set_skipped
		return 1
	fi
	clean_logs

	t0=`date +%s`
	echo "1-Populating filesystem..."
	# create 3 files of each type
	# (*.1, *.2, *.3, *.4)
	for i in `seq 1 4`; do
		dd if=/dev/zero of=$ROOT/file.$i bs=1M count=1 >/dev/null 2>/dev/null || error "$? writting $ROOT/file.$i"
		dd if=/dev/zero of=$ROOT/foo.$i bs=1M count=1 >/dev/null 2>/dev/null || error "$? writting $ROOT/foo.$i"
		dd if=/dev/zero of=$ROOT/bar.$i bs=1M count=1 >/dev/null 2>/dev/null || error "$? writting $ROOT/bar.$i"

		if (( $is_lhsm != 0 )); then
			flush_data
			lfs hsm_archive $ROOT/file.$i $ROOT/foo.$i $ROOT/bar.$i
		fi
	done

	if (( $is_lhsm != 0 )); then
		wait_done 60 || error "Copy timeout"
	fi


	# scan
	echo "2-Populating robinhood database (scan)..."
	$RH -f ./cfg/$config_file --scan --once -l DEBUG -L rh_scan.log

	# make sure files are old enough
	sleep 2

	# start periodic trigger in background
	echo "3.1-checking trigger for first policy..."
	$RH -f ./cfg/$config_file --purge -l DEBUG -L rh_purge.log &
	sleep 2
	
	t1=`date +%s`
	((delta=$t1 - $t0))

	# it first must have purged *.1 files (not others)
	check_released "$ROOT/file.1" || error "$ROOT/file.1 should have been released"
	check_released "$ROOT/foo.1"  || error "$ROOT/foo.1 should have been released"
	check_released "$ROOT/bar.1"  || error "$ROOT/bar.1 should have been released"
	check_released "$ROOT/file.2" && error "$ROOT/file.2 shouldn't have been released after $delta s"
	check_released "$ROOT/foo.2"  && error "$ROOT/foo.2 shouldn't have been released after $delta s"
	check_released "$ROOT/bar.2"  && error "$ROOT/bar.2 shouldn't have been released after $delta s"

	sleep $(( $sleep_time + 2 ))
	# now, *.2 must have been purged
	echo "3.2-checking trigger for second policy..."

	check_released "$ROOT/file.2" || error "$ROOT/file.2 should have been released"
	check_released "$ROOT/foo.2" || error "$ROOT/foo.2 should have been released"
	check_released "$ROOT/bar.2" || error "$ROOT/bar.2 should have been released"
	check_released "$ROOT/file.3" && error "$ROOT/file.3 shouldn't have been released"
	check_released "$ROOT/foo.3"  && error "$ROOT/foo.3 shouldn't have been released"
	check_released "$ROOT/bar.3" && error "$ROOT/bar.3 shouldn't have been released"

	sleep $(( $sleep_time + 2 ))
	# now, it's *.3
	# *.4 must be preserved
	echo "3.3-checking trigger for third policy..."

	check_released "$ROOT/file.3" || error "$ROOT/file.3 should have been released"
	check_released "$ROOT/foo.3"  || error "$ROOT/foo.3 should have been released"
	check_released "$ROOT/bar.3"  || error "$ROOT/bar.3 should have been released"
	check_released "$ROOT/file.4" && error "$ROOT/file.4 shouldn't have been released"
	check_released "$ROOT/foo.4"  && error "$ROOT/foo.4 shouldn't have been released"
	check_released "$ROOT/bar.4"  && error "$ROOT/bar.4 shouldn't have been released"

	# final check: 3x "Purge summary: 3 entries"
	nb_pass=`grep "Purge summary: 3 entries" rh_purge.log | wc -l`
	if (( $nb_pass == 3 )); then
		echo "OK: triggered 3 times"
	else
		error "unexpected trigger count $nb_pass"
	fi

	# terminate
	pkill -9 $PROC
}

function fileclass_test
{
	config_file=$1
	sleep_time=$2
	policy_str="$3"

	if (( $is_lhsm + $is_hsmlite == 0 )); then
		echo "HSM test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# create test tree

	mkdir -p $ROOT/dir_A
	mkdir -p $ROOT/dir_B
	mkdir -p $ROOT/dir_C

	# classes are:
	# 1) even_and_B
	# 2) even_and_not_B
	# 3) odd_or_A
	# 4) other

	echo "data" > $ROOT/dir_A/file.0 #2
	echo "data" > $ROOT/dir_A/file.1 #3
	echo "data" > $ROOT/dir_A/file.2 #2
	echo "data" > $ROOT/dir_A/file.3 #3
	echo "data" > $ROOT/dir_A/file.x #3
	echo "data" > $ROOT/dir_A/file.y #3

	echo "data" > $ROOT/dir_B/file.0 #1
	echo "data" > $ROOT/dir_B/file.1 #3
	echo "data" > $ROOT/dir_B/file.2 #1
	echo "data" > $ROOT/dir_B/file.3 #3

	echo "data" > $ROOT/dir_C/file.0 #2
	echo "data" > $ROOT/dir_C/file.1 #3
	echo "data" > $ROOT/dir_C/file.2 #2
	echo "data" > $ROOT/dir_C/file.3 #3
	echo "data" > $ROOT/dir_C/file.x #4
	echo "data" > $ROOT/dir_C/file.y #4

	# => 2x 1), 4x 2), 8x 3), 2x 4)

	echo "1bis-Sleeping $sleep_time seconds..."
	sleep $sleep_time

	# read changelogs
	if (( $no_log )); then
		echo "2-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "2-Reading changelogs..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi

	echo "3-Applying migration policy ($policy_str)..."
	# start a migration files should notbe migrated this time
	$RH -f ./cfg/$config_file --migrate -l DEBUG -L rh_migr.log  --once || error ""

	# count the number of file for each policy
	nb_pol1=`grep hints rh_migr.log | grep even_and_B | wc -l`
	nb_pol2=`grep hints rh_migr.log | grep even_and_not_B | wc -l`
	nb_pol3=`grep hints rh_migr.log | grep odd_or_A | wc -l`
	nb_pol4=`grep hints rh_migr.log | grep unmatched | wc -l`

	#nb_pol1=`grep "matches the condition for policy 'inter_migr'" rh_migr.log | wc -l`
	#nb_pol2=`grep "matches the condition for policy 'union_migr'" rh_migr.log | wc -l`
	#nb_pol3=`grep "matches the condition for policy 'not_migr'" rh_migr.log | wc -l`
	#nb_pol4=`grep "matches the condition for policy 'default'" rh_migr.log | wc -l`

	(( $nb_pol1 == 2 )) || error "********** TEST FAILED: wrong count of matching files for fileclass 'even_and_B': $nb_pol1"
	(( $nb_pol2 == 4 )) || error "********** TEST FAILED: wrong count of matching files for fileclass 'even_and_not_B': $nb_pol2"
	(( $nb_pol3 == 8 )) || error "********** TEST FAILED: wrong count of matching files for fileclass 'odd_or_A': $nb_pol3"
	(( $nb_pol4 == 2 )) || error "********** TEST FAILED: wrong count of matching files for fileclass 'unmatched': $nb_pol4"

	(( $nb_pol1 == 2 )) && (( $nb_pol2 == 4 )) && (( $nb_pol3 == 8 )) \
		&& (( $nb_pol4 == 2 )) && echo "OK: test successful"
}

function test_info_collect
{
	config_file=$1
	sleep_time1=$2
	sleep_time2=$3
	policy_str="$4"

	clean_logs

	# test reading changelogs or scanning with strange names, etc...
	mkdir $ROOT'/dir with blanks'
	mkdir $ROOT'/dir with "quotes"'
	mkdir "$ROOT/dir with 'quotes'"

	touch $ROOT'/dir with blanks/file 1'
	touch $ROOT'/dir with blanks/file with "double" quotes'
	touch $ROOT'/dir with "quotes"/file with blanks'
	touch "$ROOT/dir with 'quotes'/file with 1 quote: '"

	sleep $sleep_time1

	# read changelogs
	if (( $no_log )); then
		echo "1-Scanning..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
		nb_cr=0
	else
		echo "1-Reading changelogs..."
		#$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
		$RH -f ./cfg/$config_file --readlog -l FULL -L rh_chglogs.log  --once || error ""
		nb_cr=4
	fi

	sleep $sleep_time2

	grep "DB query failed" rh_chglogs.log && error ": a DB query failed when reading changelogs"

	nb_create=`grep ChangeLog rh_chglogs.log | grep 01CREAT | wc -l`
	nb_db_apply=`grep STAGE_DB_APPLY rh_chglogs.log | tail -1 | cut -d '|' -f 6 | cut -d ':' -f 2 | tr -d ' '`

	if (( $is_lhsm + $is_hsmlite != 0 )); then
		db_expect=4
	else
		db_expect=7
	fi
	# 4 files have been created, 4 db operations expected (files)
	# tmp_fs_mgr purpose: +3 for mkdir operations
	if (( $nb_create == $nb_cr && $nb_db_apply == $db_expect )); then
		echo "OK: $nb_cr files created, $db_expect database operations"
	else
		error ": unexpected number of operations: $nb_create files created, $nb_db_apply database operations"
		return 1
	fi

	clean_logs

	echo "2-Scanning..."
	$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
#	$RH -f ./cfg/$config_file --scan -l FULL -L rh_chglogs.log  --once || error ""
 
	grep "DB query failed" rh_chglogs.log && error ": a DB query failed when scanning"
	nb_db_apply=`grep STAGE_DB_APPLY rh_chglogs.log | tail -1 | cut -d '|' -f 6 | cut -d ':' -f 2 | tr -d ' '`

	# 4 db operations expected (1 for each file)
	if (( $nb_db_apply == $db_expect )); then
		echo "OK: $db_expect database operations"
	else
#		grep ENTRIES rh_chglogs.log
		error ": unexpected number of operations: $nb_db_apply database operations"
	fi
}

function readlog_chk
{
	config_file=$1

	echo "Reading changelogs..."
	$RH -f ./cfg/$config_file --readlog -l FULL -L rh_chglogs.log  --once || error "reading logs"
	grep "DB query failed" rh_chglogs.log && error ": a DB query failed: `grep 'DB query failed' rh_chglogs.log | tail -1`"
	clean_logs
}

function scan_chk
{
	config_file=$1

	echo "Scanning..."
        $RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error "scanning filesystem"
	grep "DB query failed" rh_chglogs.log && error ": a DB query failed: `grep 'DB query failed' rh_chglogs.log | tail -1`"
	clean_logs
}

function test_info_collect2
{
	config_file=$1
	flavor=$2
	policy_str="$3"

	clean_logs

	if (($no_log != 0 && $flavor != 1 )); then
		echo "Changelogs not supported on this config: skipped"
		set_skipped
		return 1
	fi

	# create 10k entries
	../fill_fs.sh $ROOT 10000 >/dev/null

	# flavor 1: scan only x3
	# flavor 2: mixed (readlog/scan/readlog/scan)
	# flavor 3: mixed (readlog/readlog/scan/scan)
	# flavor 4: mixed (scan/scan/readlog/readlog)

	if (( $flavor == 1 )); then
		scan_chk $config_file
		scan_chk $config_file
		scan_chk $config_file
	elif (( $flavor == 2 )); then
		readlog_chk $config_file
		scan_chk    $config_file
		# touch entries before reading log
		../fill_fs.sh $ROOT 10000 >/dev/null
		readlog_chk $config_file
		scan_chk    $config_file
	elif (( $flavor == 3 )); then
		readlog_chk $config_file
		# touch entries before reading log again
		../fill_fs.sh $ROOT 10000 >/dev/null
		readlog_chk $config_file
		scan_chk    $config_file
		scan_chk    $config_file
	elif (( $flavor == 4 )); then
		scan_chk    $config_file
		scan_chk    $config_file
		readlog_chk $config_file
		# touch entries before reading log again
		../fill_fs.sh $ROOT 10000 >/dev/null
		readlog_chk $config_file
	else
		error "Unexpexted test flavor '$flavor'"
	fi
}


function test_pools
{
	config_file=$1
	sleep_time=$2
	policy_str="$3"

	create_pools

	clean_logs

	# create files in different pools (or not)
	touch $ROOT/no_pool.1 || error "creating file"
	touch $ROOT/no_pool.2 || error "creating file"
	lfs setstripe -p lustre.$POOL1 $ROOT/in_pool_1.a || error "creating file in $POOL1"
	lfs setstripe -p lustre.$POOL1 $ROOT/in_pool_1.b || error "creating file in $POOL1"
	lfs setstripe -p lustre.$POOL2 $ROOT/in_pool_2.a || error "creating file in $POOL2"
	lfs setstripe -p lustre.$POOL2 $ROOT/in_pool_2.b || error "creating file in $POOL2"

	sleep $sleep_time

	# read changelogs
	if (( $no_log )); then
		echo "1.1-scan and match..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""
	else
		echo "1.1-read changelog and match..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once || error ""
	fi


	echo "1.2-checking report output..."
	# check classes in report output
	$REPORT -f ./cfg/$config_file --dump-all -c > report.out || error ""
	cat report.out

	echo "1.3-checking robinhood log..."
	grep "Missing attribute" rh_chglogs.log && error "missing attribute when matching classes"

	# purge field index
	if (( $is_lhsm != 0 )); then
		pf=7
	else
		pf=5
	fi	

	# no_pool files must match default
	for i in 1 2; do
		(( $is_lhsm + $is_hsmlite != 0 )) &&  \
			( [ `grep "$ROOT/no_pool.$i" report.out | cut -d ',' -f 6 | tr -d ' '` = "[default]" ] || error "bad migr class for no_pool.$i" )
		 (( $is_hsmlite == 0 )) && \
			([ `grep "$ROOT/no_pool.$i" report.out | cut -d ',' -f $pf | tr -d ' '` = "[default]" ] || error "bad purg class for no_pool.$i")
	done

	for i in a b; do
		# in_pool_1 files must match pool_1
		(( $is_lhsm  + $is_hsmlite != 0 )) && \
			 ( [ `grep "$ROOT/in_pool_1.$i" report.out | cut -d ',' -f 6  | tr -d ' '` = "pool_1" ] || error "bad migr class for in_pool_1.$i" )
		(( $is_hsmlite == 0 )) && \
			([ `grep "$ROOT/in_pool_1.$i" report.out | cut -d ',' -f $pf | tr -d ' '` = "pool_1" ] || error "bad purg class for in_pool_1.$i")

		# in_pool_2 files must match pool_2
		(( $is_lhsm + $is_hsmlite != 0 )) && ( [ `grep "$ROOT/in_pool_2.$i" report.out  | cut -d ',' -f 6 | tr -d ' '` = "pool_2" ] || error "bad migr class for in_pool_2.$i" )
		(( $is_hsmlite == 0 )) && \
			([ `grep "$ROOT/in_pool_2.$i" report.out  | cut -d ',' -f $pf | tr -d ' '` = "pool_2" ] || error "bad purg class for in_pool_2.$i")
	done

	# rematch and recheck
	echo "2.1-scan and match..."
	# read changelogs
	$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once || error ""

	echo "2.2-checking report output..."
	# check classes in report output
	$REPORT -f ./cfg/$config_file --dump-all -c  > report.out || error ""
	cat report.out

	# no_pool files must match default
	for i in 1 2; do
		(( $is_lhsm + $is_hsmlite != 0 )) && ( [ `grep "$ROOT/no_pool.$i" report.out | cut -d ',' -f 6 | tr -d ' '` = "[default]" ] || error "bad migr class for no_pool.$i" )
		(( $is_hsmlite == 0 )) && \
			([ `grep "$ROOT/no_pool.$i" report.out | cut -d ',' -f $pf | tr -d ' '` = "[default]" ] || error "bad purg class for no_pool.$i")
	done

	for i in a b; do
		# in_pool_1 files must match pool_1
		(( $is_lhsm + $is_hsmlite != 0 )) &&  ( [ `grep "$ROOT/in_pool_1.$i" report.out | cut -d ',' -f 6  | tr -d ' '` = "pool_1" ] || error "bad migr class for in_pool_1.$i" )
		(( $is_hsmlite == 0 )) && \
			([ `grep "$ROOT/in_pool_1.$i" report.out | cut -d ',' -f $pf | tr -d ' '` = "pool_1" ] || error "bad purg class for in_pool_1.$i")

		# in_pool_2 files must match pool_2
		(( $is_lhsm + $is_hsmlite != 0 )) && ( [ `grep "$ROOT/in_pool_2.$i" report.out  | cut -d ',' -f 6 | tr -d ' '` = "pool_2" ] || error "bad migr class for in_pool_2.$i" )
		(( $is_hsmlite == 0 )) && \
			([ `grep "$ROOT/in_pool_2.$i" report.out  | cut -d ',' -f $pf | tr -d ' '` = "pool_2" ] || error "bad purg class for in_pool_2.$i")
	done

	echo "2.3-checking robinhood log..."
	grep "Missing attribute" rh_chglogs.log && error "missing attribute when matching classes"

}

function test_logs
{
	config_file=$1
	flavor=$2
	policy_str="$3"

	sleep_time=430 # log rotation time (300) + scan interval (100) + scan duration (30)

	clean_logs
	rm -f /tmp/test_log.1 /tmp/test_report.1 /tmp/test_alert.1

	# test flavors (x=supported):
	# x	file_nobatch
	# x 	file_batch
	# x	syslog_nobatch
	# x	syslog_batch
	# x	stdio_nobatch
	# x	stdio_batch
	# 	mix
	files=0
	syslog=0
	batch=0
	stdio=0
	echo $flavor | grep nobatch > /dev/null || batch=1
	echo $flavor | grep syslog_ > /dev/null && syslog=1
	echo $flavor | grep file_ > /dev/null && files=1
	echo $flavor | grep stdio_ > /dev/null && stdio=1
	echo "Test parameters: files=$files, syslog=$syslog, stdio=$stdio, batch=$batch"

	# create files
	touch $ROOT/file.1 || error "creating file"
	touch $ROOT/file.2 || error "creating file"
	touch $ROOT/file.3 || error "creating file"
	touch $ROOT/file.4 || error "creating file"

	if (( $is_lhsm != 0 )); then
		flush_data
		lfs hsm_archive $ROOT/file.*
		wait_done 60 || error "Copy timeout"
	fi

	if (( $syslog )); then
		init_msg_idx=`wc -l /var/log/messages | awk '{print $1}'`
	fi

	# run a scan
	if (( $stdio )); then
		$RH -f ./cfg/$config_file --scan -l DEBUG --once >/tmp/rbh.stdout 2>/tmp/rbh.stderr || error ""
	else
		$RH -f ./cfg/$config_file --scan -l DEBUG --once || error ""
	fi

	if (( $files )); then
		log="/tmp/test_log.1"
		alert="/tmp/test_alert.1"
		report="/tmp/test_report.1"
	elif (( $stdio )); then
                log="/tmp/rbh.stderr"
		if (( $batch )); then
			# batch output to file has no ALERT header on each line
			# we must extract between "ALERT REPORT" and "END OF ALERT REPORT"
        		local old_ifs="$IFS"
        		IFS=$'\t\n :'
			alert_lines=(`grep -n ALERT /tmp/rbh.stdout | cut -d ':' -f 1 | xargs`)
			IFS="$old_ifs"
		#	echo ${alert_lines[0]}
		#	echo ${alert_lines[1]}
			((nbl=${alert_lines[1]}-${alert_lines[0]}+1))
			# extract nbl lines stating from line alert_lines[0]:
			tail -n +${alert_lines[0]} /tmp/rbh.stdout | head -n $nbl > /tmp/extract_alert
		else
			grep ALERT /tmp/rbh.stdout > /tmp/extract_alert
		fi
		# grep 'robinhood\[' => don't select lines with no headers
		grep -v ALERT /tmp/rbh.stdout | grep "$CMD[^ ]*\[" > /tmp/extract_report
		alert="/tmp/extract_alert"
		report="/tmp/extract_report"
	elif (( $syslog )); then
        # wait for syslog to flush logs to disk
        sync; sleep 2
		tail -n +"$init_msg_idx" /var/log/messages | grep $CMD > /tmp/extract_all
		egrep -v 'ALERT' /tmp/extract_all | grep  ': [A-Za-Z ]* \|' > /tmp/extract_log
		egrep -v 'ALERT|: [A-Za-Z ]* \|' /tmp/extract_all > /tmp/extract_report
		grep 'ALERT' /tmp/extract_all > /tmp/extract_alert

		log="/tmp/extract_log"
		alert="/tmp/extract_alert"
		report="/tmp/extract_report"
	else
		error ": unsupported test option"
		return 1
	fi
	
	# check if there is something written in the log
	if (( `wc -l $log | awk '{print $1}'` > 0 )); then
		echo "OK: log file is not empty"
	else
		error ": empty log file"
	fi

	if (( $batch )); then
		#check summary
		sum=`grep "alert summary" $alert | wc -l`
		(($sum==1)) || (error ": no summary found" ; cat $alert)
		# check alerts about file.1 and file.2
		# search for line ' * 1 alert_file1', ' * 1 alert_file2'
		a1=`egrep -e "[0-9]* alert_file1" $alert | sed -e 's/.* \([0-9]*\) alert_file1/\1/' | xargs`
		a2=`egrep -e "[0-9]* alert_file2" $alert | sed -e 's/.* \([0-9]*\) alert_file2/\1/' | xargs`
		e1=`grep ${ROOT}'/file\.1' $alert | wc -l`
		e2=`grep ${ROOT}'/file\.2' $alert | wc -l`
		# search for alert count: "2 alerts:"
		if (($syslog)); then
			all=`egrep -e "\| [0-9]* alerts:" $alert | sed -e 's/.*| \([0-9]*\) alerts:/\1/' | xargs`
		else
			all=`egrep -e "^[0-9]* alerts:" $alert | sed -e 's/^\([0-9]*\) alerts:/\1/' | xargs`
		fi
		if (( $a1 == 1 && $a2 == 1 && $e1 == 1 && $e2 == 1 && $all == 2)); then
			echo "OK: 2 alerts"
		else
			error ": invalid alert counts: $a1,$a2,$e1,$e2,$all"
			cat $alert
		fi
	else
		# check alerts about file.1 and file.2
		a1=`grep alert_file1 $alert | wc -l`
		a2=`grep alert_file2 $alert | wc -l`
		e1=`grep 'Entry: '${ROOT}'/file\.1' $alert | wc -l`
		e2=`grep 'Entry: '${ROOT}'/file\.2' $alert | wc -l`
		all=`grep "Robinhood alert" $alert | wc -l`
		if (( $a1 == 1 && $a2 == 1 && $e1 == 1 && $e2 == 1 && $all == 2)); then
			echo "OK: 2 alerts"
		else
			error ": invalid alert counts: $a1,$a2,$e1,$e2,$all"
			cat $alert
		fi
	fi

	# no purge for now
	if (( `wc -l $report | awk '{print $1}'` == 0 )); then
                echo "OK: no action reported"
        else
                error ": there are reported actions after a scan"
		cat $report
        fi
	
	if (( $is_hsmlite == 0 )); then

		# reinit msg idx
		if (( $syslog )); then
			init_msg_idx=`wc -l /var/log/messages | awk '{print $1}'`
		fi

		# run a purge
		rm -f $log $report $alert

		if (( $stdio )); then
			$RH -f ./cfg/$config_file --purge-fs=0 -l DEBUG --dry-run >/tmp/rbh.stdout 2>/tmp/rbh.stderr || error ""
		else
			$RH -f ./cfg/$config_file --purge-fs=0 -l DEBUG --dry-run || error ""
		fi

		# extract new syslog messages
		if (( $syslog )); then
            # wait for syslog to flush logs to disk
            sync; sleep 2
			tail -n +"$init_msg_idx" /var/log/messages | grep $CMD > /tmp/extract_all
			egrep -v 'ALERT' /tmp/extract_all | grep  ': [A-Za-Z ]* \|' > /tmp/extract_log
			egrep -v 'ALERT|: [A-Za-Z ]* \|' /tmp/extract_all > /tmp/extract_report
			grep 'ALERT' /tmp/extract_all > /tmp/extract_alert
		elif (( $stdio )); then
			grep ALERT /tmp/rbh.stdout > /tmp/extract_alert
			# grep 'robinhood\[' => don't select lines with no headers
			grep -v ALERT /tmp/rbh.stdout | grep "$CMD[^ ]*\[" > /tmp/extract_report
		fi

		# check that there is something written in the log
		if (( `wc -l $log | awk '{print $1}'` > 0 )); then
			echo "OK: log file is not empty"
		else
			error ": empty log file"
		fi

		# check alerts (should be impossible to purge at 0%)
		grep "Could not purge" $alert > /dev/null
		if (($?)); then
			error ": alert should have been raised for impossible purge"
		else
			echo "OK: alert raised"
		fi

		# all files must have been purged
		if (( `wc -l $report | awk '{print $1}'` == 4 )); then
			echo "OK: 4 actions reported"
		else
			error ": unexpected count of actions"
			cat $report
		fi
		
	fi
	(($files==1)) || return 0

	if [[ "x$SLOW" != "x1" ]]; then
		echo "Quick tests only: skipping log rotation test (use SLOW=1 to enable this test)"
		return 1
	fi

	# start a FS scanner with FS_Scan period = 100
	$RH -f ./cfg/$config_file --scan -l DEBUG &

	# rotate the logs
	for l in /tmp/test_log.1 /tmp/test_report.1 /tmp/test_alert.1; do
		mv $l $l.old
	done

	sleep $sleep_time

	# check that there is something written in the log
	if (( `wc -l /tmp/test_log.1 | awk '{print $1}'` > 0 )); then
		echo "OK: log file is not empty"
	else
		error ": empty log file"
	fi

	# check alerts about file.1 and file.2
	a1=`grep alert_file1 /tmp/test_alert.1 | wc -l`
	a2=`grep alert_file2 /tmp/test_alert.1 | wc -l`
	e1=`grep 'Entry: '${ROOT}'/file\.1' /tmp/test_alert.1 | wc -l`
	e2=`grep 'Entry: '${ROOT}'/file\.2' /tmp/test_alert.1 | wc -l`
	all=`grep "Robinhood alert" /tmp/test_alert.1 | wc -l`
	if (( $a1 > 0 && $a2 > 0 && $e1 > 0 && $e2 > 0 && $all >= 2)); then
		echo "OK: $all alerts"
	else
		error ": invalid alert counts: $a1,$a2,$e1,$e2,$all"
		cat /tmp/test_alert.1
	fi

	# no purge during scan 
	if (( `wc -l /tmp/test_report.1 | awk '{print $1}'` == 0 )); then
                echo "OK: no action reported"
        else
                error ": there are reported actions after a scan"
		cat /tmp/test_report.1
        fi

	pkill -9 $PROC
	rm -f /tmp/test_log.1 /tmp/test_report.1 /tmp/test_alert.1
	rm -f /tmp/test_log.1.old /tmp/test_report.1.old /tmp/test_alert.1.old
}

function test_cfg_parsing
{
	flavor=$1
	dummy=$2
	policy_str="$3"

	clean_logs

	# needed for reading password file
	if [[ ! -f /etc/robinhood.d/.dbpassword ]]; then
		if [[ ! -d /etc/robinhood.d ]]; then
			mkdir /etc/robinhood.d
		fi
		echo robinhood > /etc/robinhood.d/.dbpassword
	fi

	if [[ $flavor == "basic" ]]; then

		if (($is_hsmlite)) ; then
			TEMPLATE=$TEMPLATE_DIR"/hsmlite_basic.conf"
		elif (($is_lhsm)); then
			TEMPLATE=$TEMPLATE_DIR"/hsm_policy_basic.conf"
		else
			TEMPLATE=$TEMPLATE_DIR"/tmp_fs_mgr_basic.conf"
		fi

	elif [[ $flavor == "detailed" ]]; then

		if (($is_hsmlite)) ; then
			TEMPLATE=$TEMPLATE_DIR"/hsmlite_detailed.conf"
		elif (($is_lhsm)); then
			TEMPLATE=$TEMPLATE_DIR"/hsm_policy_detailed.conf"
		else
			TEMPLATE=$TEMPLATE_DIR"/tmp_fs_mgr_detailed.conf"
		fi

	elif [[ $flavor == "generated" ]]; then

		GEN_TEMPLATE="/tmp/template.$CMD"
		TEMPLATE=$GEN_TEMPLATE
		$RH --template=$TEMPLATE || error "generating config template"
	else
		error "invalid test flavor"
		return 1
	fi

	# test parsing
	$RH --test-syntax -f "$TEMPLATE" 2>rh_syntax.log >rh_syntax.log || error " reading config file \"$TEMPLATE\""

	cat rh_syntax.log
	grep "unknown parameter" rh_syntax.log > /dev/null && error "unexpected parameter"
	grep "read successfully" rh_syntax.log > /dev/null && echo "OK: parsing succeeded"

}

function recovery_test
{
	config_file=$1
	flavor=$2
	policy_str="$3"

	if (( $is_hsmlite == 0 )); then
		echo "Backup test only: skipped"
		set_skipped
		return 1
	fi

	clean_logs

	# flavors:
	# full: all entries fully recovered
	# delta: all entries recovered but some with deltas
	# rename: some entries have been renamed since they have been saved
	# partial: some entries can't be recovered
	# mixed: all of them
	if [[ $flavor == "full" ]]; then
		nb_full=20
		nb_rename=0
		nb_delta=0
		nb_nobkp=0
	elif [[ $flavor == "delta" ]]; then
		nb_full=10
		nb_rename=0
		nb_delta=10
		nb_nobkp=0
	elif [[ $flavor == "rename" ]]; then
		nb_full=10
		nb_rename=10
		nb_delta=0
		nb_nobkp=0
	elif [[ $flavor == "partial" ]]; then
                nb_full=10
		nb_rename=0
                nb_delta=0
                nb_nobkp=10
	elif [[ $flavor == "mixed" ]]; then
                nb_full=5
		nb_rename=5
                nb_delta=5
                nb_nobkp=5
	else
		error "Invalid arg in recovery_test"
		return 1
	fi
	# read logs
	

	# create files
	((total=$nb_full + $nb_rename + $nb_delta + $nb_nobkp))
	echo "1.1-creating files..."
	for i in `seq 1 $total`; do
		mkdir "$ROOT/dir.$i" || error "$? creating directory $ROOT/dir.$i"
		if (( $i % 3 == 0 )); then
			chmod 755 "$ROOT/dir.$i" || error "$? setting mode of $ROOT/dir.$i"
		elif (( $i % 3 == 1 )); then
			chmod 750 "$ROOT/dir.$i" || error "$? setting mode of $ROOT/dir.$i"
		elif (( $i % 3 == 2 )); then
			chmod 700 "$ROOT/dir.$i" || error "$? setting mode of $ROOT/dir.$i"
		fi

		dd if=/dev/zero of=$ROOT/dir.$i/file.$i bs=1M count=1 >/dev/null 2>/dev/null || error "$? writting $ROOT/file.$i"
	done

	# read changelogs
	if (( $no_log )); then
		echo "1.2-scan..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once 2>/dev/null || error "scanning"
	else
		echo "1.2-read changelog..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once 2>/dev/null || error "reading log"
	fi

	sleep 2

	# all files are new
	new_cnt=`$REPORT -f ./cfg/$config_file -l MAJOR --csv -i | grep new | cut -d ',' -f 2`
	echo "$new_cnt files are new"
	(( $new_cnt == $total )) || error "20 new files expected"

	echo "2.1-archiving files..."
	# archive and modify files
	for i in `seq 1 $total`; do
		if (( $i <= $nb_full )); then
			$RH -f ./cfg/$config_file --migrate-file "$ROOT/dir.$i/file.$i" --ignore-policies -l DEBUG -L rh_migr.log 2>/dev/null \
				|| error "archiving $ROOT/dir.$i/file.$i"
		elif (( $i <= $(($nb_full+$nb_rename)) )); then
			$RH -f ./cfg/$config_file --migrate-file "$ROOT/dir.$i/file.$i" --ignore-policies -l DEBUG -L rh_migr.log 2>/dev/null \
				|| error "archiving $ROOT/dir.$i/file.$i"
			mv "$ROOT/dir.$i/file.$i" "$ROOT/dir.$i/file_new.$i" || error "renaming file"
			mv "$ROOT/dir.$i" "$ROOT/dir.new_$i" || error "renaming dir"
		elif (( $i <= $(($nb_full+$nb_rename+$nb_delta)) )); then
			$RH -f ./cfg/$config_file --migrate-file "$ROOT/dir.$i/file.$i" --ignore-policies -l DEBUG -L rh_migr.log 2>/dev/null \
				|| error "archiving $ROOT/dir.$i/file.$i"
			touch "$ROOT/dir.$i/file.$i"
		elif (( $i <= $(($nb_full+$nb_rename+$nb_delta+$nb_nobkp)) )); then
			# no backup
			:
		fi
	done

	if (( $no_log )); then
		echo "2.2-scan..."
		$RH -f ./cfg/$config_file --scan -l DEBUG -L rh_chglogs.log  --once 2>/dev/null || error "scanning"
	else
		echo "2.2-read changelog..."
		$RH -f ./cfg/$config_file --readlog -l DEBUG -L rh_chglogs.log  --once 2>/dev/null || error "reading log"
	fi

	$REPORT -f ./cfg/$config_file -l MAJOR --csv -i > /tmp/report.$$
	new_cnt=`grep "new" /tmp/report.$$ | cut -d ',' -f 2`
	mod_cnt=`grep "modified" /tmp/report.$$ | cut -d ',' -f 2`
	sync_cnt=`grep "synchro" /tmp/report.$$ | cut -d ',' -f 2`
	[[ -z $new_cnt ]] && new_cnt=0
	[[ -z $mod_cnt ]] && mod_cnt=0
	[[ -z $sync_cnt ]] && sync_cnt=0

	echo "new: $new_cnt, modified: $mod_cnt, synchro: $sync_cnt"
	(( $sync_cnt == $nb_full+$nb_rename )) || error "Nbr of synchro files doesn't match: $sync_cnt != $nb_full + $nb_rename"
	(( $mod_cnt == $nb_delta )) || error "Nbr of modified files doesn't match: $mod_cnt != $nb_delta"
	(( $new_cnt == $nb_nobkp )) || error "Nbr of new files doesn't match: $new_cnt != $nb_nobkp"

	# shots before disaster (time is only significant for files)
	find $ROOT -type f -printf "%n %m %T@ %g %u %s %p %l\n" > /tmp/before.$$
	find $ROOT -type d -printf "%n %m %g %u %s %p %l\n" >> /tmp/before.$$
	find $ROOT -type l -printf "%n %m %g %u %s %p %l\n" >> /tmp/before.$$

	# FS disaster
	if [[ -n "$ROOT" ]]; then
		echo "3-Disaster: all FS content is lost"
		rm  -rf $ROOT/*
	fi

	# perform the recovery
	echo "4-Performing recovery..."
	cp /dev/null recov.log
	$RECOV -f ./cfg/$config_file --start -l DEBUG >> recov.log 2>&1 || error "Error starting recovery"

	$RECOV -f ./cfg/$config_file --resume -l DEBUG >> recov.log 2>&1 || error "Error performing recovery"

	$RECOV -f ./cfg/$config_file --complete -l DEBUG >> recov.log 2>&1 || error "Error completing recovery"

	find $ROOT -type f -printf "%n %m %T@ %g %u %s %p %l\n" > /tmp/after.$$
	find $ROOT -type d -printf "%n %m %g %u %s %p %l\n" >> /tmp/after.$$
	find $ROOT -type l -printf "%n %m %g %u %s %p %l\n" >> /tmp/after.$$

	diff  /tmp/before.$$ /tmp/after.$$ > /tmp/diff.$$

	# checking status and diff result
	for i in `seq 1 $total`; do
		if (( $i <= $nb_full )); then
			grep "Restoring $ROOT/dir.$i/file.$i" recov.log | egrep -e "OK\$" >/dev/null || error "Bad status (OK expected)"
			grep "$ROOT/dir.$i/file.$i" /tmp/diff.$$ && error "$ROOT/dir.$i/file.$i NOT expected to differ"
		elif (( $i <= $(($nb_full+$nb_rename)) )); then
			grep "Restoring $ROOT/dir.new_$i/file_new.$i" recov.log	| egrep -e "OK\$" >/dev/null || error "Bad status (OK expected)"
			grep "$ROOT/dir.new_$i/file_new.$i" /tmp/diff.$$ && error "$ROOT/dir.new_$i/file_new.$i NOT expected to differ"
		elif (( $i <= $(($nb_full+$nb_rename+$nb_delta)) )); then
			grep "Restoring $ROOT/dir.$i/file.$i" recov.log	| grep "OK (old version)" >/dev/null || error "Bad status (old version expected)"
			grep "$ROOT/dir.$i/file.$i" /tmp/diff.$$ >/dev/null || error "$ROOT/dir.$i/file.$i is expected to differ"
		elif (( $i <= $(($nb_full+$nb_rename+$nb_delta+$nb_nobkp)) )); then
			grep -A 1 "Restoring $ROOT/dir.$i/file.$i" recov.log | grep "No backup" >/dev/null || error "Bad status (no backup expected)"
			grep "$ROOT/dir.$i/file.$i" /tmp/diff.$$ >/dev/null || error "$ROOT/dir.$i/file.$i is expected to differ"
		fi
	done

	rm -f /tmp/before.$$ /tmp/after.$$ /tmp/diff.$$
}



function check_disabled
{
       config_file=$1
       flavor=$2
       policy_str="$3"

       clean_logs

       case "$flavor" in
               purge)
		       if (( ($is_hsmlite != 0) && ($shook == 0) )); then
			       echo "No purge for hsmlite purpose (shook=$shook): skipped"
                               set_skipped
                               return 1
                       fi
                       cmd='--purge'
                       match='Resource Monitor is disabled'
                       ;;
               migration)
                       if (( $is_hsmlite + $is_lhsm == 0 )); then
                               echo "hsmlite or HSM test only: skipped"
                               set_skipped
                               return 1
                       fi
                       cmd='--migrate'
                       match='Migration module is disabled'
                       ;;
               hsm_remove) 
                       if (( $is_hsmlite + $is_lhsm == 0 )); then
                               echo "hsmlite or HSM test only: skipped"
                               set_skipped
                               return 1
                       fi
                       cmd='--hsm-remove'
                       match='HSM removal successfully initialized' # enabled by default
                       ;;
               rmdir) 
                       if (( $is_hsmlite + $is_lhsm != 0 )); then
                               echo "No rmdir policy for hsmlite or HSM purpose: skipped"
                               set_skipped
                               return 1
                       fi
                       cmd='--rmdir'
                       match='Directory removal is disabled'
                       ;;
               class)
                       cmd='--scan'
                       match='disabling class matching'
                       ;;
               *)
                       error "unexpected flavor $flavor"
                       return 1 ;;
       esac

       echo "1.1. Performing action $cmd (daemon mode)..."
        $RH -f ./cfg/$config_file $cmd -l DEBUG -L rh_scan.log -p rh.pid &

       sleep 2
       echo "1.2. Checking that kill -HUP does not terminate the process..."
       kill -HUP $(cat rh.pid)
       sleep 2
       [[ -f /proc/$(cat rh.pid)/status ]] || error "process terminated on kill -HUP"

       kill $(cat rh.pid)
       sleep 2
       rm -f rh.pid

       grep "$match" rh_scan.log || error "log should contain \"$match\""

       cp /dev/null rh_scan.log
       echo "2. Performing action $cmd (one shot)..."
        $RH -f ./cfg/$config_file $cmd --once -l DEBUG -L rh_scan.log

       grep "$match" rh_scan.log || error "log should contain \"$match\""
               
}



only_test=""
quiet=0
junit=0

while getopts qj o
do	case "$o" in
	q)	quiet=1;;
	j)	junit=1;;
	[?])	print >&2 "Usage: $0 [-q] [-j] test_nbr ..."
		exit 1;;
	esac
done
shift $(($OPTIND-1))

if [[ -n "$1" ]]; then
	only_test=$1
fi

# initialize tmp files for XML report
function junit_init
{
	cp /dev/null $TMPXML_PREFIX.stderr
	cp /dev/null $TMPXML_PREFIX.stdout
	cp /dev/null $TMPXML_PREFIX.tc
}

# report a success for a test
function junit_report_success # (class, test_name, time)
{
	class="$1"
	name="$2"
	time="$3"

	# remove quotes in name
	name=`echo "$name" | sed -e 's/"//g'`

	echo "<testcase classname=\"$class\" name=\"$name\" time=\"$time\" />" >> $TMPXML_PREFIX.tc
}

# report a failure for a test
function junit_report_failure # (class, test_name, time, err_type)
{
	class="$1"
	name="$2"
	time="$3"
	err_type="$4"

	# remove quotes in name
	name=`echo "$name" | sed -e 's/"//g'`

	echo "<testcase classname=\"$class\" name=\"$name\" time=\"$time\">" >> $TMPXML_PREFIX.tc
	echo -n "<failure type=\"$err_type\"><![CDATA[" >> $TMPXML_PREFIX.tc
	cat $TMPERR_FILE	>> $TMPXML_PREFIX.tc
	echo "]]></failure>" 	>> $TMPXML_PREFIX.tc
	echo "</testcase>" 	>> $TMPXML_PREFIX.tc
}

function junit_write_xml # (time, nb_failure, tests)
{
	time=$1
	failure=$2
	tests=$3
	
	cp /dev/null $XML
#	echo "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>" > $XML
	echo "<?xml version=\"1.0\" encoding=\"ISO8859-2\" ?>" > $XML
	echo "<testsuite name=\"robinhood.LustreTests\" errors=\"0\" failures=\"$failure\" tests=\"$tests\" time=\"$time\">" >> $XML
	cat $TMPXML_PREFIX.tc 		>> $XML
	echo -n "<system-out><![CDATA[" >> $XML
	cat $TMPXML_PREFIX.stdout 	>> $XML
	echo "]]></system-out>"		>> $XML
	echo -n "<system-err><![CDATA[" >> $XML
	cat $TMPXML_PREFIX.stderr 	>> $XML
	echo "]]></system-err>" 	>> $XML
	echo "</testsuite>"		>> $XML
}


function cleanup
{
	echo "cleanup..."
        if (( $quiet == 1 )); then
                clean_fs | tee "rh_test.log" | egrep -i -e "OK|ERR|Fail|skip|pass"
        else
                clean_fs
        fi
}

function run_test
{
	if [[ -n $6 ]]; then args=$6; else args=$5 ; fi

	index=$1
	shift

	index_clean=`echo $index | sed -e 's/[a-z]//'`

	if [[ -z $only_test || "$only_test" = "$index" || "$only_test" = "$index_clean" ]]; then
		cleanup
		echo
		echo "==== TEST #$index $2 ($args) ===="

		error_reset
	
		t0=`date "+%s.%N"`

		if (($junit == 1)); then
			# markup in log
			echo "==== TEST #$index $2 ($args) ====" >> $TMPXML_PREFIX.stdout
			echo "==== TEST #$index $2 ($args) ====" >> $TMPXML_PREFIX.stderr
			"$@" 2>> $TMPXML_PREFIX.stderr >> $TMPXML_PREFIX.stdout
		elif (( $quiet == 1 )); then
			"$@" 2>&1 > rh_test.log
			egrep -i -e "OK|ERR|Fail|skip|pass" rh_test.log
		else
			"$@"
		fi

		t1=`date "+%s.%N"`
		dur=`echo "($t1-$t0)" | bc -l`
		echo "duration: $dur sec"

		if (( $DO_SKIP )); then
			echo "(TEST #$index : skipped)" >> $SUMMARY
			SKIP=$(($SKIP+1))
		elif (( $NB_ERROR > 0 )); then
			echo "TEST #$index : *FAILED*" >> $SUMMARY
			RC=$(($RC+1))
			if (( $junit )); then
				junit_report_failure "robinhood.$PURPOSE.Lustre" "Test #$index: $args" "$dur" "ERROR" 
			fi
		else
			echo "TEST #$index : OK" >> $SUMMARY
			SUCCES=$(($SUCCES+1))
			if (( $junit )); then
				junit_report_success "robinhood.$PURPOSE.Lustre" "Test #$index: $args" "$dur"
			fi
		fi
	fi
}

# clear summary
cp /dev/null $SUMMARY

#init xml report
if (( $junit )); then
	junit_init
	tinit=`date "+%s.%N"`
fi

######### TEST FAMILIES ########
# 1xx - collecting info and database
# 2xx - policy matching
# 3xx - triggers
# 4xx - reporting
# 5xx - internals, misc.
################################

##### info collect. + DB tests #####

run_test 100	test_info_collect info_collect.conf 1 1 "escape string in SQL requests"
run_test 101a    test_info_collect2  info_collect2.conf  1 "scan x3"
run_test 101b 	test_info_collect2  info_collect2.conf	2 "readlog/scan x2"
run_test 101c 	test_info_collect2  info_collect2.conf	3 "readlog x2 / scan x2"
run_test 101d 	test_info_collect2  info_collect2.conf	4 "scan x2 / readlog x2"
run_test 102	update_test test_updt.conf 5 30 "db update policy"
run_test 103a    test_acct_table common.conf 5 "Acct table and triggers creation"
run_test 103b    test_acct_table acct_group.conf 5 "Acct table and triggers creation"
run_test 103c    test_acct_table acct_user.conf 5 "Acct table and triggers creation"
run_test 103d    test_acct_table acct_user_group.conf 5 "Acct table and triggers creation"


#### policy matching tests  ####

run_test 200	path_test test_path.conf 2 "path matching policies"
run_test 201	migration_test test1.conf 11 31 "last_mod>30s"
run_test 202	migration_test test2.conf 5  31 "last_mod>30s and name == \"*[0-5]\""
run_test 203	migration_test test3.conf 5  16 "complex policy with filesets"
run_test 204	migration_test test3.conf 10 31 "complex policy with filesets"
run_test 205	xattr_test test_xattr.conf 5 "xattr-based fileclass definition"
run_test 206	purge_test test_purge.conf 11 21 "last_access > 20s"
run_test 207	purge_size_filesets test_purge2.conf 2 3 "purge policies using size-based filesets"
run_test 208	periodic_class_match_migr test_updt.conf 10 "periodic fileclass matching (migration)"
run_test 209	periodic_class_match_purge test_updt.conf 10 "periodic fileclass matching (purge)"
run_test 210	fileclass_test test_fileclass.conf 2 "complex policies with unions and intersections of filesets"
run_test 211	test_pools test_pools.conf 1 "class matching with condition on pools"
run_test 212	link_unlink_remove_test test_rm1.conf 1 31 "deferred hsm_remove (30s)"
run_test 213	migration_test_single test1.conf 11 31 "last_mod>30s"
run_test 214a  check_disabled  common.conf  purge      "no purge if not defined in config"
run_test 214b  check_disabled  common.conf  migration  "no migration if not defined in config"
run_test 214c  check_disabled  common.conf  rmdir      "no rmdir if not defined in config"
run_test 214d  check_disabled  common.conf  hsm_remove "hsm_rm is enabled by default"
run_test 214e  check_disabled  common.conf  class      "no class matching if none defined in config"
run_test 215	mass_softrm    test_rm1.conf 31 1000    "rm are detected between 2 scans"
run_test 216   test_maint_mode test_maintenance.conf 30 45 "pre-maintenance mode" 5

	
#### triggers ####

run_test 300	test_cnt_trigger test_trig.conf 101 21 "trigger on file count"
run_test 301    test_ost_trigger test_trig2.conf 100 80 "trigger on OST usage"
run_test 302	test_trigger_check test_trig3.conf 60 110 "triggers check only" 40 80 5 10
run_test 303    test_periodic_trigger test_trig4.conf 10 "periodic trigger"

#### reporting ####
run_test 400	test_rh_report common.conf 3 1 "reporting tool"

run_test 401a   test_rh_acct_report common.conf 5 "reporting tool: config file without acct param"
run_test 401b   test_rh_acct_report acct_user.conf 5 "reporting tool: config file with acct_user=true and acct_group=false"
run_test 401c   test_rh_acct_report acct_group.conf 5 "reporting tool: config file with acct_user=false and acct_group=true"
run_test 401d   test_rh_acct_report no_acct.conf 5 "reporting tool: config file with acct_user=false and acct_group=false"
run_test 401e   test_rh_acct_report acct_user_group.conf 5 "reporting tool: config file with acct_user=true and acct_group=true"

run_test 402a   test_rh_report_split_user_group common.conf 5 "" "report with split-user-groups option"
run_test 402b   test_rh_report_split_user_group common.conf 5 "--force-no-acct" "report with split-user-groups and force-no-acct option"

#### misc, internals #####
run_test 500a	test_logs log1.conf file_nobatch 	"file logging without alert batching"
run_test 500b	test_logs log2.conf syslog_nobatch 	"syslog without alert batching"
run_test 500c	test_logs log3.conf stdio_nobatch 	"stdout and stderr without alert batching"
run_test 500d	test_logs log1b.conf file_batch 	"file logging with alert batching"
run_test 500e	test_logs log2b.conf syslog_batch 	"syslog with alert batching"
run_test 500f	test_logs log3b.conf stdio_batch 	"stdout and stderr with alert batching"

run_test 501a 	test_cfg_parsing basic none		"parsing of basic template"
run_test 501b 	test_cfg_parsing detailed none		"parsing of detailed template"
run_test 501c 	test_cfg_parsing generated none		"parsing of generated template"

run_test 502a    recovery_test	test_recov.conf  full    "FS recovery"
run_test 502b    recovery_test	test_recov.conf  delta   "FS recovery with delta"
run_test 502c    recovery_test	test_recov.conf  rename  "FS recovery with renamed entries"
run_test 502d    recovery_test	test_recov.conf  partial "FS recovery with missing hsmlites"
run_test 502e    recovery_test	test_recov.conf  mixed   "FS recovery (mixed status)"

echo
echo "========== TEST SUMMARY ($PURPOSE) =========="
cat $SUMMARY
echo "============================================="

#init xml report
if (( $junit )); then
	tfinal=`date "+%s.%N"`
	dur=`echo "($tfinal-$tinit)" | bc -l`
	echo "total test duration: $dur sec"
	junit_write_xml "$dur" $RC $(( $RC + $SUCCES ))
	rm -f $TMPXML_PREFIX.stderr $TMPXML_PREFIX.stdout $TMPXML_PREFIX.tc
fi

rm -f $SUMMARY
if (( $RC > 0 )); then
	echo "$RC tests FAILED, $SUCCES successful, $SKIP skipped"
else
	echo "All tests passed ($SUCCES successful, $SKIP skipped)"
fi
rm -f $TMPERR_FILE
exit $RC
