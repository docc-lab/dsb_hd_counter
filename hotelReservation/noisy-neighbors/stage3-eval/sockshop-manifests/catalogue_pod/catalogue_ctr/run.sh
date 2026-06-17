#!/bin/bash

WORKSPACE_NAME="catalogue_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${CATALOGUE_DB_DIAL_ADDR+x}" ]; then
		echo "    CATALOGUE_DB_DIAL_ADDR (missing)"
	else
		echo "    CATALOGUE_DB_DIAL_ADDR=$CATALOGUE_DB_DIAL_ADDR"
	fi
	if [ -z "${CATALOGUE_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "    CATALOGUE_SERVICE_GRPC_BIND_ADDR (missing)"
	else
		echo "    CATALOGUE_SERVICE_GRPC_BIND_ADDR=$CATALOGUE_SERVICE_GRPC_BIND_ADDR"
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


catalogue_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${CATALOGUE_DB_DIAL_ADDR+x}" ]; then
		if ! catalogue_db_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${CATALOGUE_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		if ! catalogue_service_grpc_bind_addr; then
			return $?
		fi
	fi

	run_catalogue_proc() {
		
        cd catalogue_proc
        ./catalogue_proc --catalogue_db.dial_addr=$CATALOGUE_DB_DIAL_ADDR --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --catalogue_service.grpc.bind_addr=$CATALOGUE_SERVICE_GRPC_BIND_ADDR &
        CATALOGUE_PROC=$!
        return $?

	}

	if run_catalogue_proc; then
		if [ -z "${CATALOGUE_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting catalogue_proc: function catalogue_proc did not set CATALOGUE_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started catalogue_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting catalogue_proc due to exitcode ${exitcode} from catalogue_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running catalogue_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${CATALOGUE_DB_DIAL_ADDR+x}" ]; then
		echo "  CATALOGUE_DB_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CATALOGUE_DB_DIAL_ADDR=$CATALOGUE_DB_DIAL_ADDR"
	fi
	
	if [ -z "${CATALOGUE_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "  CATALOGUE_SERVICE_GRPC_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CATALOGUE_SERVICE_GRPC_BIND_ADDR=$CATALOGUE_SERVICE_GRPC_BIND_ADDR"
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

	catalogue_proc
	
	wait
}

run_all
