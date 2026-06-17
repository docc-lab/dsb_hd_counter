#!/bin/bash

WORKSPACE_NAME="shipping_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${SHIPPING_DB_DIAL_ADDR+x}" ]; then
		echo "    SHIPPING_DB_DIAL_ADDR (missing)"
	else
		echo "    SHIPPING_DB_DIAL_ADDR=$SHIPPING_DB_DIAL_ADDR"
	fi
	if [ -z "${SHIPPING_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "    SHIPPING_SERVICE_GRPC_BIND_ADDR (missing)"
	else
		echo "    SHIPPING_SERVICE_GRPC_BIND_ADDR=$SHIPPING_SERVICE_GRPC_BIND_ADDR"
	fi
	if [ -z "${SHIPPING_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    SHIPPING_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    SHIPPING_SERVICE_GRPC_DIAL_ADDR=$SHIPPING_SERVICE_GRPC_DIAL_ADDR"
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


shipping_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${SHIPPING_DB_DIAL_ADDR+x}" ]; then
		if ! shipping_db_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${SHIPPING_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		if ! shipping_service_grpc_bind_addr; then
			return $?
		fi
	fi

	if [ -z "${SHIPPING_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! shipping_service_grpc_dial_addr; then
			return $?
		fi
	fi

	run_shipping_proc() {
		
        cd shipping_proc
        ./shipping_proc --shipping_db.dial_addr=$SHIPPING_DB_DIAL_ADDR --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --shipping_service.grpc.bind_addr=$SHIPPING_SERVICE_GRPC_BIND_ADDR --shipping_service.grpc.dial_addr=$SHIPPING_SERVICE_GRPC_DIAL_ADDR &
        SHIPPING_PROC=$!
        return $?

	}

	if run_shipping_proc; then
		if [ -z "${SHIPPING_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting shipping_proc: function shipping_proc did not set SHIPPING_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started shipping_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting shipping_proc due to exitcode ${exitcode} from shipping_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running shipping_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${SHIPPING_DB_DIAL_ADDR+x}" ]; then
		echo "  SHIPPING_DB_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  SHIPPING_DB_DIAL_ADDR=$SHIPPING_DB_DIAL_ADDR"
	fi
	
	if [ -z "${SHIPPING_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "  SHIPPING_SERVICE_GRPC_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  SHIPPING_SERVICE_GRPC_BIND_ADDR=$SHIPPING_SERVICE_GRPC_BIND_ADDR"
	fi
	
	if [ -z "${SHIPPING_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  SHIPPING_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  SHIPPING_SERVICE_GRPC_DIAL_ADDR=$SHIPPING_SERVICE_GRPC_DIAL_ADDR"
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

	shipping_proc
	
	wait
}

run_all
