#!/bin/bash

WORKSPACE_NAME="user_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${USER_DB_DIAL_ADDR+x}" ]; then
		echo "    USER_DB_DIAL_ADDR (missing)"
	else
		echo "    USER_DB_DIAL_ADDR=$USER_DB_DIAL_ADDR"
	fi
	if [ -z "${USER_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "    USER_SERVICE_GRPC_BIND_ADDR (missing)"
	else
		echo "    USER_SERVICE_GRPC_BIND_ADDR=$USER_SERVICE_GRPC_BIND_ADDR"
	fi
	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		echo "    ZIPKIN_DIAL_ADDR (missing)"
	else
		echo "    ZIPKIN_DIAL_ADDR=$ZIPKIN_DIAL_ADDR"
	fi
		
	exit 1; 
}

while getopts "h" flag; do
	case $flag in
		*)
		usage
		;;
	esac
done


user_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${USER_DB_DIAL_ADDR+x}" ]; then
		if ! user_db_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${USER_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		if ! user_service_grpc_bind_addr; then
			return $?
		fi
	fi

	run_user_proc() {
		
        cd user_proc
        ./user_proc --user_db.dial_addr=$USER_DB_DIAL_ADDR --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --user_service.grpc.bind_addr=$USER_SERVICE_GRPC_BIND_ADDR &
        USER_PROC=$!
        return $?

	}

	if run_user_proc; then
		if [ -z "${USER_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting user_proc: function user_proc did not set USER_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started user_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting user_proc due to exitcode ${exitcode} from user_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running user_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${USER_DB_DIAL_ADDR+x}" ]; then
		echo "  USER_DB_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  USER_DB_DIAL_ADDR=$USER_DB_DIAL_ADDR"
	fi
	
	if [ -z "${USER_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "  USER_SERVICE_GRPC_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  USER_SERVICE_GRPC_BIND_ADDR=$USER_SERVICE_GRPC_BIND_ADDR"
	fi
	
	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		echo "  ZIPKIN_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  ZIPKIN_DIAL_ADDR=$ZIPKIN_DIAL_ADDR"
	fi
		

	if [ "$missing_vars" -gt 0 ]; then
		echo "Aborting due to missing environment variables"
		return 1
	fi

	user_proc
	
	wait
}

run_all
