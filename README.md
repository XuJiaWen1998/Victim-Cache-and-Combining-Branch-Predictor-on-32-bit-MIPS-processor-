# CSE 148 Final Project version 3.0

## Release v2.2 04/12/2018 Zinsser Zhang

Please refer to the wiki page **Walkthrough** for instructions to play around the design really quick.
Detailed documentations can be found in the wiki of this repository

## Release v3.0 06/10/2022 Jiawen Xu, Brian Lin

We need to do the walkthrough given by the class before we can run the code (same as baseline version).

The oss-cad-suite package did not come with the code due to the size, and it need to be downloaded based on the **Walkthrough**

Also, the Makefile need to be manually set the CSE148_TOOLS path

If the oss-cad-suite folder is as the same location as the Makefile, we can simply set 

```
CSE148_TOOLS=.
```

We have more sv files added to our design and make sure the verilator_files has same content as below

To build, we basically need to run command:

```
make verilate
```

To run the benchmark, we need to run below command after make:

```
obj_dir/Vmips_core -b <benchmark>
```
