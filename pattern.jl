using HDF5, JLD

if isdefined(current_module(),:LastMain) && isdefined(LastMain,:Iterators)
  using LastMain.Iterators
else
  using Iterators
end


rng = MersenneTwister()


###########################################
#problem definitions
###########################################


#############################################
#Parameters
#############################################
α = 1.0; #Probability of following ATC command
const g_noaction = (0, :∅)
const g_nullAct = [0,0]


#############################################
#Set up states
NextStates = (Symbol => Array{Symbol, 1})[]
#############################################

function addConn!(d, f, t)
    if haskey(d,f)
        push!(d[f], t)
        d[f] = unique(d[f])
    else
        d[f] = [t]
    end
end

normalTrans = { [:T,  :R, :U1, :LX1, :LD1, :LD2, :LB1, :F1, :R, :T];
                            [:U1, :RX1, :RD1, :RD2, :RB1, :F1];
                  [:F1, :GO, :U1, :U2, :LX2, :LD0, :LD1, :LD2, :LD3, :LB2, :F0, :F1];
                                 [:U2, :RX2, :RD0, :RD1, :RD2, :RD3, :RB2, :F0];
                                        [:U2, :LDep, :LArr, :LD1];[:LArr, :LD2];[:LArr, :LD3];
                                        [:U2, :RDep, :RArr, :RD1];[:RArr, :RD2];[:RArr, :RD3];}

allstates = [];
for k in 1:size(normalTrans, 1)
  for i in 2:length(normalTrans[k])
      addConn!(NextStates, normalTrans[k][i-1], normalTrans[k][i])
  end
  allstates = unique([allstates, normalTrans[k]])
end
sn = (Symbol => Int64)[]
for i in 1:length(allstates)
    sn[allstates[i]] = i
end

const g_allstates = allstates;
const g_sn = sn;
const g_allstates_string = (ASCIIString)[string(a) for a in g_allstates]


#Add transition times for each state in minutes
teaTime = (Symbol => Float64)[]
teaTime[:T] = 5
teaTime[:R] = 0.5
teaTime[:GO] = 1

teaTime[:U1] = 1; teaTime[:U2] = 2

teaTime[:LX1] = teaTime[:LX2] = 0.5

teaTime[:LD0] = 2
teaTime[:LD1] = teaTime[:LD2] = 1.5
teaTime[:LD3] = 2

teaTime[:LB1] = teaTime[:LB2] = 0.5

teaTime[:F0] = 2; teaTime[:F1] = 1
teaTime[:LDep] = 10; teaTime[:LArr] = 2


function symmetrize!(halfDict, symFun)
for astr in g_allstates_string
  if(astr[1] == 'R')
    astr_l = replace(astr, 'R', 'L')
    a = symbol(astr)
    b = symbol(astr_l)
    if b in keys(halfDict)
      halfDict[a] = symFun(halfDict[b])
    end
  end
end
end

symmetrize!(teaTime, x -> x)

using Base.Test
@test length(teaTime) == length(g_allstates)



#############################################
## Possible transitions
#############################################
function getNextPerms(ss::Array{Symbol,1})
  Nac = length(ss)
  ss_pos = [NextStates[s] for s in ss]

  ss_next = typeof(ss)[]
  for p in product(ss_pos...)
    push!(ss_next, Symbol[s for s in p])
  end

  return ss_next
end


#############################################
#coordinates
#############################################
dx = 2.; dy = 2.;
xy = Dict([:T, :R, :U1, :LX1, :LD1, :LD2, :LB1, :F1],
          {[0,-1] , [0, 0], [dx, 0], [1.5*dx, dy/2], [dx,dy], [-dx, dy], [-1.5*dx, dy/2], [-dx, 0]});
xy[:F0]  = [-2*dx, 0];
xy[:GO]  = [0, dy/2];
xy[:U2]  =  [2*dx, 0];
xy[:LX2] = [2.5*dx, dy/2];
xy[:LD0] = [2*dx, dy];
xy[:LD3] = [-2*dx, dy];
xy[:LB2] = [-2.5*dx, dy/2];
xy[:LDep] = [dx, 2*dy]
xy[:LArr] = [-dx, 2*dy]

symmetrize!(xy, x -> [x[1], -x[2]])


##
#############################################
##Printing to do file for vizualization
#############################################
#for f in keys(NextStates)
#    @printf("%s[label=\"%s(%i)\", pos=\"%.2f, %.2f\"]\n", f, f, sn[f], xy[f][1], xy[f][2])
#end
#for f in keys(NextStates)
#    for t in NextStates[f]
#        @printf("%s -> %s\n", f, t)
#    end
#end



#############################################
#Probability of following ATC command
#############################################
function weightedChoice(weights)
    rnd = rand(rng) * sum(weights)
    for (i, w) in enumerate(weights)
        rnd -= w
        if rnd < 0
            return i
        end
    end
end

#############################################
function randomChoice(from::Symbol, receivedATC::Bool, atcDesired::Symbol)
#############################################
    snext = NextStates[from]
    pnext = Float64[probFromTo(from, to, receivedATC, atcDesired) for to in snext]

    return snext[weightedChoice(pnext)]
end

#############################################
function probFromTo(from::Symbol, to::Symbol, receivedATC::Bool, atcDesired::Symbol)
#############################################
    p = 0.
    allNext = NextStates[from]
    if to in allNext
        Nnext = length(allNext);
        #Only one option, use it
        if Nnext == 1
            p = 1.
        #Not addressing this aircraft or invalid atc command
        elseif !receivedATC || !(atcDesired in allNext)
            #except for taxi (aircraft will not take-off unless told so)
            #All other states are equally likely
            if(from != :T)
              p = 1./ Nnext
            #i.e. from Taxi -> Taxi without ATC commands
            elseif (to == :T)
                p = α
            #From Taxi -> other things..
            else
                p = (1-α)/(Nnext-1)
            end
        #received ATC command, collaborate!
        else
          if to == atcDesired
            p = α
          else
            p = (1-α)/(Nnext-1)
          end
        end
    end
    return p
end




#############################################
function validActions(S)
#############################################
  A = [g_noaction]; sizehint(A, 10);
  for (i, s) in enumerate(S)
    #Can't tell departing aircrafts what to do
    if !(s in [:LDep, :RDep])
      snext = NextStates[s]
      if(length(snext) > 1)
        for sn in snext
          #Can't tell aircraft to depart...
          if !(sn in [:LDep, :RDep])
            push!(A, (i, sn))
          end
        end
      end
    end
  end
  return A
end

function extAct2compAct(act::typeof(g_noaction), S)
  cAct = copy(g_nullAct)
  if act != g_noaction
    sidx = act[1]
    cAct[1] = sidx
    for (cidx, s) in enumerate(NextStates[S[sidx]])
      if s == act[2]
        cAct[2] = cidx
      end
    end
  end
  return cAct
end

function compAct2extAct(act::typeof(g_nullAct), S)
  eAct = copy(g_noaction)
  if act != g_nullAct && act[1] > 0 && act[1] <= length(S)
    sidx = act[1]
    Sp = NextStates[S[sidx]]
    if act[2] <= length(Sp) #otherwise not a valid action!
      eAct = (act[1], Sp[act[2]])
    end
  end
  return eAct
end

#Could probably rewrite this to not have to call everything
#else and instead just use the number of next available states!
function validCompactActions(S)
  actions = validActions(S)
  compActions = Array(typeof(g_nullAct),length(actions),1)
  for (idx, act) in enumerate(actions)
    compActions[idx] = extAct2compAct(act, S)
  end
  return compActions
end
#############################################
function Transition(S::Array{Symbol,1}, a::typeof(g_noaction), Snext::Array{Symbol,1})
#############################################
    p = 1.;
    idx = 1;
    for (from, to) in zip(S, Snext)
        p *= probFromTo(from, to, idx == a[1], a[2])
        idx += 1;
    end
    return p;
end


function Transition(S::Array{Symbol,1}, acomp::typeof(g_nullAct), Snext::Array{Symbol,1})
  aext = compAct2extAct(acomp, S)
  return Transition(S, aext, Snext)
end






#############################################
function simulate(s; policy::Dict = Dict(), N=10)
  return simulate(s, (s-> policy[s]), N)
end

function simulate(s, policy::Function; N=10, endEarly = false)
#############################################
    S = {s}
    A = {g_noaction}
    for step in 1:N
        Snow = S[end]
        a = policy(Snow)
        Snew = deepcopy(Snow)
        for i in 1:length(Snow)
            Snew[i] = randomChoice(Snow[i], a[1] == i, a[2])
        end
        push!(S, Snew)
        push!(A, a)
        if(endEarly && NcolNtaxi(Snew)[1] != 0)
          break;
        end
    end
    A = A[2:end];
    rewards = Float64[Reward(s, a) for (s, a) in zip(S,A)];
    collisions = [NcolNtaxi(s)[1] for s in S]
    return S, A, collisions, rewards
end



#############################################
function plotSim(S, Actions, collisions, rewards; animation = false, Ncolprev = 0)
#############################################
    M = "";

    xrange = 6.; yrange = 5.;
    if(animation)
      M = "o"
      ax = PyPlot.subplot(1,1,1)
    else
      ax = PyPlot.subplot(2,1,1)
    end

    for s in g_allstates
      (x, y) = xy[s]
        PyPlot.text(x, y, s, fontsize=10, alpha=0.8, bbox={"facecolor" => "white", "alpha"=>0.2})
    end

    colors = ["blue", "green", "black", "red"]
    for n in 1:length(S[1])
        x = [xy[s[n]][1] for s in S]+(n-1)*.1
        y = [xy[s[n]][2] for s in S]+(n-1)*.05
        PyPlot.plot(x, y, linestyle="--", linewidth = 2, color=colors[n]);
        if(animation)
          M = (n == Actions[end][1]) ? "D" : "o"
          PyPlot.plot(x[end], y[end], linestyle="", color=colors[n], marker=M);
          if(M == "D")
             text(x[end], y[end], Actions[end][2], fontsize=12)
          end
        end
    end


    cidx = find(x -> x >= 1, collisions)
    Nc = float(length(cidx));
    NcolSum = cumsum(collisions);
    RewardSum = cumsum(rewards)/1000.;

    NcCount = Dict(g_allstates, zeros(size(g_allstates)));
    if(Nc > 0.)
      if(animation)
        cidx = [cidx[end]]
      end
      Nsum = 0
      for ss in S[cidx]
        for s in unique(ss)
          if s != :T
            NcCount[s] += (c = count(x -> x == s, ss) - 1)
            Nsum += c
          end
        end
      end

      for s in g_allstates
            msize = int(50.*NcCount[s]/Nsum)
            x = xy[s][1]; y = xy[s][2];
            if animation
                msize = min(msize, 10)
            end
            if msize > 0
                PyPlot.plot(x, y, marker="o", color="red", markersize = msize, alpha = 0.9);
            end
      end
    end

    if animation
      #PyPlot.title("Total Collisions = " * string(collisions[end] + Ncolprev))
    end
    ax[:set_xlim]([-.9, 1]*xrange);
    ax[:set_ylim]([-1, 1]*yrange);
    ax[:set_yticklabels]([]); ax[:set_xticklabels]([])
    #PyPlot.grid("on")



    if (!animation)
      ax = PyPlot.subplot(2,1,2)
      PyPlot.plot(-NcolSum, color="red")
      PyPlot.plot(RewardSum, color="blue")
      ax[:set_ylim]([minimum([RewardSum, NcolSum]), 0.01]);
      PyPlot.grid("on")
      PyPlot.legend(["Number of Collisions", "R / 1000."])
    end

end




