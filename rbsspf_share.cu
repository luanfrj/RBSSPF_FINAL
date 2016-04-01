#include"rbsspf_share.cuh"

__global__
void kernelSetupRandomSeed(int *seed, thrust::random::minstd_rand *rng)
{
    GetThreadID_1D(rid);
    if(rid>=MAXPN) return;
    rng[rid]=thrust::minstd_rand(seed[rid]);
    return;
}

//====================================================

__host__
int hostCollectBeamCount(int *d_beamcount, int *h_beamcount, int tmppnum)
{
    cudaMemcpy(h_beamcount,d_beamcount,sizeof(int)*tmppnum,cudaMemcpyDeviceToHost);
    for(int i=1;i<tmppnum;i++)
    {
        h_beamcount[i]+=h_beamcount[i-1];
    }
    cudaMemcpy(d_beamcount,h_beamcount,sizeof(int)*tmppnum,cudaMemcpyHostToDevice);
    return h_beamcount[tmppnum-1];
}

__global__
void kernelSetupBeamArray(int *beamcount, int tmppnum, TrackerBeamEvaluator *beamevaluators)
{
    GetThreadID_1D(tmppid);
    if(tmppid>=tmppnum) return;
    int startid=tmppid>0?beamcount[tmppid-1]:0;
    int endid=beamcount[tmppid];
    for(int i=startid;i<endid;i++)
    {
        beamevaluators[i].tmppid=tmppid;
        beamevaluators[i].beamdelta=i-startid;
        beamevaluators[i].weight=0;
        beamevaluators[i].validflag=0;
    }
}

__global__
void kernelMeasureScan(TrackerBeamEvaluator *beamevaluators, int beamcount, TrackerParticle *tmpparticles, TrackerSampleControl *controls, double *scan, int beamnum, bool motionflag)
{
    GetThreadID_1D(measureid);
    if(measureid>=beamcount) return;
    TrackerBeamEvaluator evaluator=beamevaluators[measureid];

    int tmppid=evaluator.tmppid;
    TrackerParticle particle=tmpparticles[tmppid];

    int cid=particle.controlid;
    double iteration=motionflag?controls[cid].motioniteration:controls[cid].geometryiteration;
    if(iteration<1) return;
    double anneal=motionflag?controls[cid].motionanneal:controls[cid].geometryanneal;

    int beamid=particle.geometry.startbeamid+evaluator.beamdelta;
    int edgeid=beamid<particle.geometry.midbeamid?particle.geometry.startid:particle.geometry.midid;
    beamid%=beamnum;

    double bear=2*PI/beamnum*beamid-PI;
    double length=scan[beamid];

    double lx=cos(bear);
    double ly=sin(bear);

    double sa=particle.geometry.sa[edgeid];
    double sb=lx*particle.geometry.dy[edgeid]-particle.geometry.dx[edgeid]*ly;
    double l=sa/sb*particle.geometry.cn[edgeid];

    int nextedgeid=(edgeid+1)%4;
    double cn=lx*particle.geometry.dx[nextedgeid]+ly*particle.geometry.dy[nextedgeid];

    double l0=l-MARGIN0/cn;
    double l1=l-MARGIN1/cn;
    double l2=l;
    double l3=l+MARGIN2/cn;

    double delta,w1,w2;
    double tmplogweight;
    if(length<=l0)
    {
//        tmplogweight=0;
        delta=length-l0;
        w1=WEIGHT0-WEIGHT0;
        w2=WEIGHT1-WEIGHT0;
        tmplogweight=(w1+(w2-w1)*exp(-delta*delta/0.01));
        beamevaluators[measureid].validflag=0;
    }
    else if(length<=l1)
    {
//        tmplogweight=WEIGHT1-WEIGHT0;
        delta=length-l1;
        w1=WEIGHT1-WEIGHT0;
        w2=WEIGHT2-WEIGHT0;
        tmplogweight=(w1+(w2-w1)*exp(-delta*delta/0.01));
        beamevaluators[measureid].validflag=0;
    }
    else if(length<=l3)
    {
        delta=length-l2;
        w1=WEIGHT2-WEIGHT0;
        w2=2*w1;
        tmplogweight=(w1+(w2-w1)*exp(-delta*delta/0.01));
        beamevaluators[measureid].validflag=1;
    }
    else
    {
//        tmplogweight=WEIGHT3-WEIGHT0;
        delta=length-l3;
        w1=WEIGHT3-WEIGHT0;
        w2=WEIGHT2-WEIGHT0;
        tmplogweight=(w1+(w2-w1)*exp(-delta*delta/0.01));
        beamevaluators[measureid].validflag=0;
    }
    beamevaluators[measureid].weight=tmplogweight/anneal;
}

__global__
void kernelAccumulateWeight(double * weights, int * controlids, TrackerParticle * tmpparticles, int *beamcount, int tmppnum, TrackerBeamEvaluator *beamevaluators)
{
    GetThreadID_1D(tmppid);
    if(tmppid>=tmppnum) return;

    weights[tmppid]=0;
    controlids[tmppid]=tmpparticles[tmppid].controlid;

    int startid=tmppid>0?beamcount[tmppid-1]:0;
    int endid=beamcount[tmppid];
    if(startid==endid) return;

    tmpparticles[tmppid].count=0;
    for(int i=startid;i<endid;i++)
    {
        weights[tmppid]+=beamevaluators[i].weight;
        tmpparticles[tmppid].count+=beamevaluators[i].validflag?1:0;
    }
}

//====================================================

__host__
int hostDownSampleIDs(int & startid, int * controlids, double * weights, int tmppnum, TrackerSampleControl * controls, int * sampleids, int * wcount, bool motionflag)
{
    int cid=controlids[startid];

    double maxlogweight=weights[startid];
    double minlogweight=weights[startid];
    int endid=startid;
    while(++endid<tmppnum)
    {
        if(cid!=controlids[endid]) break;
        maxlogweight=maxlogweight>weights[endid]?maxlogweight:weights[endid];
        minlogweight=minlogweight<weights[endid]?minlogweight:weights[endid];
    }

    double iteration=motionflag?controls[cid].motioniteration:controls[cid].geometryiteration;

    if(iteration<1)
    {
        int rqpn=(endid-startid)/SPN;
        for(int i=0;i<rqpn;i++)
        {
            sampleids[i]=startid+i*SPN;
            wcount[i]=0;
        }
        controls[cid].pnum=rqpn;
    }
    else
    {
        double maxscale=maxlogweight<30?1:30/maxlogweight;
        double minscale=minlogweight>-30?1:-30/minlogweight;
        double scale=maxscale<minscale?maxscale:minscale;

        weights[startid]=exp(weights[startid]*scale);
        for(int i=startid+1;i<endid;i++)
        {
            weights[i]=exp(weights[i]*scale);
            weights[i]+=weights[i-1];
        }

        int rqpn=endid-startid;
        rqpn=rqpn<RQPN?rqpn:RQPN;

        double step=1.0/rqpn;
        int accuracy=1e6;
        double samplebase=(rand()%accuracy)*step/accuracy;
        double weightsum=weights[endid-1];

        controls[cid].pnum=0;
        for(int i=0,j=startid;i<rqpn;i++)
        {
            double sample=samplebase+i*step;
            while(j<endid)
            {
                if(sample>weights[j]/weightsum)
                {
                    j++;
                    continue;
                }
                else
                {
                    if(controls[cid].pnum==0||j!=sampleids[controls[cid].pnum-1])
                    {
                        sampleids[controls[cid].pnum]=j;
                        wcount[controls[cid].pnum]=1;
                        controls[cid].pnum++;
                    }
                    else
                    {
                        wcount[controls[cid].pnum-1]++;
                    }
                    break;
                }
            }
        }
    }
    startid=endid;
    return controls[cid].pnum;
}

__global__
void kernelDownSample(TrackerParticle *particles, int *sampleids, int * wcount, int pnum, TrackerParticle *tmpparticles)
{
    GetThreadID_1D(pid);
    if(pid>=pnum) return;

    particles[pid]=tmpparticles[sampleids[pid]];
    particles[pid].weight=wcount[pid]>0?wcount[pid]:tmpparticles[sampleids[pid]].weight;
}

//====================================================

__host__ __device__
void deviceBuildModel(TrackerParticle & particle, int beamnum)
{
    double c=cos(particle.state.theta);
    double s=sin(particle.state.theta);

    particle.geometry.cx[0]=c*particle.state.lf-s*particle.state.wl+particle.state.x; particle.geometry.cy[0]=s*particle.state.lf+c*particle.state.wl+particle.state.y;
    particle.geometry.cx[1]=c*particle.state.lf+s*particle.state.wr+particle.state.x; particle.geometry.cy[1]=s*particle.state.lf-c*particle.state.wr+particle.state.y;
    particle.geometry.cx[2]=-c*particle.state.lb+s*particle.state.wr+particle.state.x; particle.geometry.cy[2]=-s*particle.state.lb-c*particle.state.wr+particle.state.y;
    particle.geometry.cx[3]=-c*particle.state.lb-s*particle.state.wl+particle.state.x; particle.geometry.cy[3]=-s*particle.state.lb+c*particle.state.wl+particle.state.y;

    double width=particle.state.wl+particle.state.wr;
    double length=particle.state.lf+particle.state.lb;
    particle.geometry.dx[0]=(particle.geometry.cx[1]-particle.geometry.cx[0])/width; particle.geometry.dy[0]=(particle.geometry.cy[1]-particle.geometry.cy[0])/width;
    particle.geometry.dx[1]=(particle.geometry.cx[2]-particle.geometry.cx[1])/length; particle.geometry.dy[1]=(particle.geometry.cy[2]-particle.geometry.cy[1])/length;
    particle.geometry.dx[2]=(particle.geometry.cx[3]-particle.geometry.cx[2])/width; particle.geometry.dy[2]=(particle.geometry.cy[3]-particle.geometry.cy[2])/width;
    particle.geometry.dx[3]=(particle.geometry.cx[0]-particle.geometry.cx[3])/length; particle.geometry.dy[3]=(particle.geometry.cy[0]-particle.geometry.cy[3])/length;

    for(int i=0;i<4;i++)
    {
        particle.geometry.cn[i]=sqrt(particle.geometry.cx[i]*particle.geometry.cx[i]+particle.geometry.cy[i]*particle.geometry.cy[i]);
        particle.geometry.sa[i]=(particle.geometry.cx[i]*particle.geometry.dy[i]-particle.geometry.cy[i]*particle.geometry.dx[i])/particle.geometry.cn[i];
    }

    double density=2*PI/beamnum;
    for(int i=0;i<4;i++)
    {
        int j=(i+1)%4;
        if(particle.geometry.sa[i]<=0&&particle.geometry.sa[j]>0)
        {
            particle.geometry.startid=(i+1)%4;
            double startbear=atan2(particle.geometry.cy[particle.geometry.startid],particle.geometry.cx[particle.geometry.startid])+PI;
            particle.geometry.startbeamid=int(startbear/density);

            particle.geometry.midid=(i+2)%4;
            double midbear=atan2(particle.geometry.cy[particle.geometry.midid],particle.geometry.cx[particle.geometry.midid])+PI;
            particle.geometry.midbeamid=int(midbear/density);
        }
        else if(particle.geometry.sa[i]>0&&particle.geometry.sa[j]<=0)
        {
            particle.geometry.endid=(i+1)%4;
            double endbear=atan2(particle.geometry.cy[particle.geometry.endid],particle.geometry.cx[particle.geometry.endid])+PI;
            particle.geometry.endbeamid=int(endbear/density);
        }
    }
    if(particle.geometry.midbeamid<particle.geometry.startbeamid)
    {
        particle.geometry.midbeamid+=beamnum;
    }
    if(particle.geometry.endbeamid<particle.geometry.startbeamid)
    {
        particle.geometry.endbeamid+=beamnum;
    }
    particle.geometry.beamcount=particle.geometry.endbeamid-particle.geometry.startbeamid+1;
}

__host__
void hostBuildModel(Tracker & tracker)
{
    double c=cos(tracker.mean.theta);
    double s=sin(tracker.mean.theta);

    tracker.cx[0]=c*tracker.mean.lf-s*tracker.mean.wl+tracker.mean.x; tracker.cy[0]=s*tracker.mean.lf+c*tracker.mean.wl+tracker.mean.y;
    tracker.cx[1]=c*tracker.mean.lf+s*tracker.mean.wr+tracker.mean.x; tracker.cy[1]=s*tracker.mean.lf-c*tracker.mean.wr+tracker.mean.y;
    tracker.cx[2]=-c*tracker.mean.lb+s*tracker.mean.wr+tracker.mean.x; tracker.cy[2]=-s*tracker.mean.lb-c*tracker.mean.wr+tracker.mean.y;
    tracker.cx[3]=-c*tracker.mean.lb-s*tracker.mean.wl+tracker.mean.x; tracker.cy[3]=-s*tracker.mean.lb+c*tracker.mean.wl+tracker.mean.y;
}
