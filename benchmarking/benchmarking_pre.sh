#!/bin/bash

## Benchmarking queue pre-execution script
## Creates initial env for job accounting 
## 0.01 20101105

#base=/gscmnt/gpfsdev1/benchmarking

if [ $LSB_JOBINDEX -eq 0 ] ; then
    id=$LSB_JOBID
else
    id=$LSB_JOBID\/$LSB_JOBINDEX
fi

jobdir=/tmp/$id/accounting
mkdir -p $jobdir
cd $jobdir

/usr/local/lsf/bin/procnetcpu.pl