#!/bin/bash

WORKSPACE_NAME="frontend_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${CART_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    CART_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    CART_SERVICE_GRPC_DIAL_ADDR=$CART_SERVICE_GRPC_DIAL_ADDR"
	fi
	if [ -z "${CATALOGUE_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    CATALOGUE_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    CATALOGUE_SERVICE_GRPC_DIAL_ADDR=$CATALOGUE_SERVICE_GRPC_DIAL_ADDR"
	fi
	if [ -z "${FRONTEND_HTTP_BIND_ADDR+x}" ]; then
		echo "    FRONTEND_HTTP_BIND_ADDR (missing)"
	else
		echo "    FRONTEND_HTTP_BIND_ADDR=$FRONTEND_HTTP_BIND_ADDR"
	fi
	if [ -z "${ORDER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    ORDER_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    ORDER_SERVICE_GRPC_DIAL_ADDR=$ORDER_SERVICE_GRPC_DIAL_ADDR"
	fi
	if [ -z "${USER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    USER_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    USER_SERVICE_GRPC_DIAL_ADDR=$USER_SERVICE_GRPC_DIAL_ADDR"
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


frontend_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${USER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! user_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${CATALOGUE_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! catalogue_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${CART_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! cart_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ORDER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! order_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${FRONTEND_HTTP_BIND_ADDR+x}" ]; then
		if ! frontend_http_bind_addr; then
			return $?
		fi
	fi

	run_frontend_proc() {
		
        cd frontend_proc
        ./frontend_proc --user_service.grpc.dial_addr=$USER_SERVICE_GRPC_DIAL_ADDR --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --catalogue_service.grpc.dial_addr=$CATALOGUE_SERVICE_GRPC_DIAL_ADDR --cart_service.grpc.dial_addr=$CART_SERVICE_GRPC_DIAL_ADDR --order_service.grpc.dial_addr=$ORDER_SERVICE_GRPC_DIAL_ADDR --frontend.http.bind_addr=$FRONTEND_HTTP_BIND_ADDR &
        FRONTEND_PROC=$!
        return $?

	}

	if run_frontend_proc; then
		if [ -z "${FRONTEND_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting frontend_proc: function frontend_proc did not set FRONTEND_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started frontend_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting frontend_proc due to exitcode ${exitcode} from frontend_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running frontend_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${CART_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  CART_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CART_SERVICE_GRPC_DIAL_ADDR=$CART_SERVICE_GRPC_DIAL_ADDR"
	fi
	
	if [ -z "${CATALOGUE_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  CATALOGUE_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CATALOGUE_SERVICE_GRPC_DIAL_ADDR=$CATALOGUE_SERVICE_GRPC_DIAL_ADDR"
	fi
	
	if [ -z "${FRONTEND_HTTP_BIND_ADDR+x}" ]; then
		echo "  FRONTEND_HTTP_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  FRONTEND_HTTP_BIND_ADDR=$FRONTEND_HTTP_BIND_ADDR"
	fi
	
	if [ -z "${ORDER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  ORDER_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  ORDER_SERVICE_GRPC_DIAL_ADDR=$ORDER_SERVICE_GRPC_DIAL_ADDR"
	fi
	
	if [ -z "${USER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  USER_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  USER_SERVICE_GRPC_DIAL_ADDR=$USER_SERVICE_GRPC_DIAL_ADDR"
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

	frontend_proc
	
	wait
}

run_all
