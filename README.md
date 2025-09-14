# GAMARA

**GAMARA** stands for **GuAranteed Multi-Agent Reach Avoid**.  
This repository implements our method on top of the following tools:

- [SCOTS](https://gitlab.lrz.de/matthias/SCOTSv0.2)  
- [ALTRO](https://github.com/RoboticExplorationLab/TrajectoryOptimization.jl) (we use **ALTRO v0.1**, included in this repository)

---

## Requirements
- **Julia**: 1.3.1  
- **Plots** library in Julia (`] add Plots`)  
- **C++11**

---

## Execution Steps

1. **Run ALTRO code**  
   - Set Julia’s working directory to the repository root.  
   - Running will generate `nom_tr.txt` (nominal controller).  

2. **Compile the project**  
   - Run the provided `Makefile`.  
   - This produces two executables:  
     - `run_abs_syn`: performs abstraction and synthesis.  
     - `simulation`: tests the synthesized controller with a perturbed model.  

⚠️ If you encounter `segmentation fault` or `std::bad_alloc()`, it indicates insufficient RAM.  

---

## Development Guide

### ALTRO (Planner)
- Create a new `*.jl` file (see examples).  
- Update the `dynamics!` function with your model.  
- Select number of points and sampling time.  
- Define penalty functions.  

### SCOTS (Robustifier)
- Create a new `*.hh` file (see examples).  
- Enter time-augmented dynamics (`x_dot = 1`).  
- Set all parameters in the `parameters` class.  
- No need to modify `.cpp` files.  

---

## Directory Structure
- **src/** → SCOTS library files  
- **TrajectoryOptimization/** → ALTRO library files  
- **Examples/** → Example cases (Julia files for ALTRO + ABCD example code)  

---

