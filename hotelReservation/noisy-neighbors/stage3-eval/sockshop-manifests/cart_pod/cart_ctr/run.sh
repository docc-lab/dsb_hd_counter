#!/bin/bash

WORKSPACE_NAME="cart_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${CART_DB_DIAL_ADDR+x}" ]; then
		echo "    CART_DB_DIAL_ADDR (missing)"
	else
		echo "    CART_DB_DIAL_ADDR=$CART_DB_DIAL_ADDR"
	fi
	if [ -z "${CART_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "    CART_SERVICE_GRPC_BIND_ADDR (missing)"
	else
		echo "    CART_SERVICE_GRPC_BIND_ADDR=$CART_SERVICE_GRPC_BIND_ADDR"
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


cart_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${CART_DB_DIAL_ADDR+x}" ]; then
		if ! cart_db_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${CART_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		if ! cart_service_grpc_bind_addr; then
			return $?
		fi
	fi

	run_cart_proc() {
		
        cd cart_proc
        ./cart_proc --cart_db.dial_addr=$CART_DB_DIAL_ADDR --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --cart_service.grpc.bind_addr=$CART_SERVICE_GRPC_BIND_ADDR &
        CART_PROC=$!
        return $?

	}

	if run_cart_proc; then
		if [ -z "${CART_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting cart_proc: function cart_proc did not set CART_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started cart_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting cart_proc due to exitcode ${exitcode} from cart_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running cart_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${CART_DB_DIAL_ADDR+x}" ]; then
		echo "  CART_DB_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CART_DB_DIAL_ADDR=$CART_DB_DIAL_ADDR"
	fi
	
	if [ -z "${CART_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "  CART_SERVICE_GRPC_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CART_SERVICE_GRPC_BIND_ADDR=$CART_SERVICE_GRPC_BIND_ADDR"
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

	cart_proc
	
	wait
}

run_all
