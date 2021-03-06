/*
 ============================================================================
 Name        : SMIRFsoup.cu
 Author      : vkrishnan
 Version     :
 Copyright   : Your copyright notice
 Description : Compute sum of reciprocals using STL on CPU and Thrust on GPU
 ============================================================================
 */

#include <vector>
#include "cuda.h"


#include <transforms/dedisperser.hpp>
#include <transforms/resampler.hpp>
#include <transforms/folder.hpp>
#include <transforms/ffter.hpp>
#include <transforms/dereddener.hpp>
#include <transforms/spectrumformer.hpp>
#include <transforms/birdiezapper.hpp>
#include <transforms/peakfinder.hpp>
#include <transforms/distiller.hpp>
#include <transforms/harmonicfolder.hpp>
#include <transforms/scorer.hpp>

#include "Stitcher.hpp"
#include "SMIRFsoup.hpp"
#include "SMIRFdef.hpp"
#include "ConfigManager.hpp"
#include "ShutdownManager.hpp"
#include "vivek/utilities.hpp"
#include "Rsyncer.hpp"



using namespace std;


int main(int argc, char **argv) {


	vector<UniquePoint*>* unique_points = new vector<UniquePoint*>();
	vector<int>* unique_fbs = new vector<int>();
	vector<string>* string_points = new vector<string>();

	/**
	 *  define shutdown hooks
	 */

	std::signal(SIGINT, SIG_IGN);
	std::signal(SIGTERM, ShutdownManager::manage_shutdown);


	/**
	 * Read all command line arguments
	 */

	CmdLineOptions args;
	if (read_cmdline_options(args,argc,argv) == EXIT_FAILURE)
		ErrorChecker::throw_error("Failed to parse command line arguments.");


	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after parsing command line options");


	/**
	 *  Try to load configuration files to know where filter banks are. Abort if not found.
	 */

	if(ConfigManager::load_configs(args.host, args.beam_searcher_id) == EXIT_FAILURE) {

		cerr << "Problem loading configuration files. Aborting." << endl;
		return EXIT_FAILURE;

	}

	organize(args);


	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after loading config");

	/**
	 *
	 * If Single filterbank mode, peasoup and return
	 *
	 */

		if(!args.filterbank.empty()){

			cerr << "In single filterbank mode" << endl;

			vivek::Filterbank* f = new vivek::Filterbank(args.filterbank,FILREAD,args.verbose);
			f->load_all_data();

			cerr << "Setting size to " << Utils::prev_power_of_two(f->get_nsamps()) << endl;

			args.size = Utils::prev_power_of_two(f->get_nsamps());

			vector<float> acc_list;
			AccelerationPlan acc_plan(args.acc_start, args.acc_end, args.acc_tol, args.acc_pulse_width, args.size,
					f->get_tsamp(), f->get_cfreq(), f->get_foff());
			acc_plan.generate_accel_list(0.0,acc_list);

			vector<float> dm_list;
			Dedisperser dedisperser(*f,1);
			dedisperser.generate_dm_list(args.dm_start,args.dm_end,args.dm_pulse_width,args.dm_tol);
			dm_list = dedisperser.get_dm_list();


			PUSH_NVTX_RANGE("Dedisperse",3)
			DispersionTrials<unsigned char> dispersion_trials = dedisperser.dedisperse();
			POP_NVTX_RANGE

			cerr << "Dedispersed." << endl;

			CandidateCollection all_cands;
			Peasoup peasoup(*f, args,dispersion_trials, acc_plan, nullptr , all_cands);
			UniquePoint* point = new UniquePoint();

			char ra[100];
			sigproc_to_hhmmss(f->get_value_for_key<double>(SRC_RAJ),&ra[0]);

			char dec[100];
			sigproc_to_ddmmss(f->get_value_for_key<double>(SRC_DEJ),&dec[0]);

			point->ra = ra;
			point->dec = dec;
			point->startFanbeam = 0;
			point->endFanbeam = 0;
			point->startNS = 0;
			point->endNS = 0;

			peasoup.set_point(point);

			peasoup.do_peasoup();

			all_cands.print_cand_file(stderr,0);

			delete f;

			exit(EXIT_SUCCESS);

		}




	/**
	 * Get and populate uniq points file.
	 */


	stringstream abs_uniq_points_file_name;
	abs_uniq_points_file_name << args.uniq_points_dir<< PATH_SEPERATOR <<args.uniq_points_file;

	int result = populate_unique_points(abs_uniq_points_file_name.str(),unique_points, string_points, unique_fbs,args.point_num);

	if(result == EXIT_FAILURE) 	ErrorChecker::throw_error("Problem reading unique points file. Aborting now.");

	if(unique_points->empty() || unique_fbs->empty() ){
		cerr << "Empty unique points file. Aborting now." << endl;
		return EXIT_FAILURE;
	}

	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after loading unique points file");

	cerr << "Successfully loaded unique points file." << endl;


/**
 * If dump or transfer mode, do and return. Do not peasoup.
 */
if(args.dump_mode || args.transfer_mode){

	Stitcher stitcher(args);

	if(args.dump_mode) {

		if(args.verbose) cerr <<  __func__ << ": In dump mode." <<endl;

		stitcher.stitch_and_dump(unique_points, unique_fbs);

	}
	else if(args.transfer_mode) {


		if(args.verbose) cerr <<  __func__ << ": In transfer mode to key: "<< std::hex << args.out_key <<endl;

		if(args.out_key < 0 ) {

			cerr <<  __func__ << ": Need a valid shared memory key. Specify using the -k option. Aborting now." << endl;
			return EXIT_FAILURE;

		}

		stringstream candidate_file_stream;
		candidate_file_stream << args.candidates_dir << PATH_SEPERATOR << args.candidates_file;

		cerr<< "Reading candidate file: " << candidate_file_stream.str() << endl;

		string candidate_file = candidate_file_stream.str();

		if(!file_exists(candidate_file)) {

			cerr << __func__ << ": Candidate file: '" << candidate_file << "' is not found. Aborting now." << endl;
			exit(EXIT_FAILURE);

		}


		if(args.point_num >=0) {

			vector<UniquePoint*> points;
			points.push_back(unique_points->at(args.point_num));

			if ( stitcher.stitch_and_transfer(&points,args.out_key, candidate_file, "cars") != EXIT_SUCCESS ) exit(EXIT_FAILURE);

		}

		return  stitcher.stitch_and_transfer(unique_points,args.out_key, candidate_file, "cars");


	}
	return EXIT_SUCCESS;
}




/**
 * Load all fanbeams to RAM.
 */


cerr << "Loading all fanbeams to RAM" << std::endl;

std::map<int,vivek::Filterbank*> fanbeams;

for( vector<int>::iterator fb_iterator = unique_fbs->begin(); fb_iterator != unique_fbs->end(); fb_iterator++){
	int fb = (int)*(fb_iterator);

	string fb_abs_path = ConfigManager::get_fil_file_path(args.archives_base,args.utc,fb, args.no_bp_structure);

	if(fb_abs_path.empty()) {
		cerr<< "Problem loading fb: " <<  fb << " fil file not found. Aborting now.";
		return EXIT_FAILURE;
	}

	vivek::Filterbank* f = new vivek::Filterbank(fb_abs_path, FILREAD, args.verbose);
	f->load_all_data();

	fanbeams.insert(std::map<int,vivek::Filterbank*>::value_type(fb,f));


	if( ShutdownManager::shutdown_called() ) {

		for(auto &kv : fanbeams ) delete kv.second;

		ShutdownManager::shutdown("while loading filterbanks");
	}


}

cerr<< fanbeams.size() << " Fanbeams loaded" << endl;

/**
 * Use the first filterbank to get common header details.
 */


vivek::Filterbank* ffb = fanbeams.begin() -> second ;

long data_bytes = ffb -> data_bytes;
int nsamples = ffb -> get_nsamps();
double tsamp = ffb -> get_tsamp();
double cfreq = ffb -> get_cfreq();
double foff =  ffb -> get_foff();

if(args.size ==0) args.size = Utils::prev_power_of_two(ffb->get_nsamps());

if(nsamples < ConfigManager::fft_size()){

	cerr << "Need atleast " <<  ConfigManager::fft_size() << " samples to run. Had only " << nsamples << ". Aborting"  <<  endl;
	exit(EXIT_FAILURE);

}


/**
 * Create the coincidencer. This creates the server that can get candidates whenever other nodes are done peasouping.
 */
Coincidencer* coincidencer = new Coincidencer(args, freq_bin_width/(args.size * ffb->tsamp), max_fanbeam_traversal );




/**
 *  Get zero DM candidates that happen on all beams and use this as a birdies list.
 */

Zapper* bzap = NULL;



if ( !args.zapfilename.empty() ) {

	cerr << "Using Zap file: " << args.zapfilename << endl;

	bzap = new Zapper(args.zapfilename);
}

if(args.dynamic_birdies) {

	cerr << "Generating dynamic birdies list" << endl;

	CandidateCollection zero_dm_candidates = get_zero_dm_candidates(&fanbeams,args);

	map<float,float> zap_map;


	float bin_width = freq_bin_width/(args.size * ffb->tsamp);

	for(int i=0; i< zero_dm_candidates.cands.size(); i++){

		Candidate c = zero_dm_candidates.cands[i];

		cerr << "Birdie '" << i << "'= P0: '" << 1/c.freq<< "' F0: '"<< c.freq << "' W: '" << bin_width << "' nfb: " <<
				c.assoc.size()<< endl;

		if(c.assoc.size() > max_fanbeam_traversal){

			zap_map.insert( map<float,float>::value_type(c.freq,bin_width));

		}

	}


	if(! zap_map.empty()) {

		if(bzap) bzap->append_from_map(&zap_map);
		else 	 bzap = new Zapper(&zap_map);

	}

	if(args.verbose) cerr << "Found "<< zap_map.size() << " birdies" << endl;

	ostringstream birdies_file;

	birdies_file << args.smirf_utc_dir << PATH_SEPERATOR << args.utc << ".birdies.BS" <<setfill('0') << setw(2) << ConfigManager::this_bs();

	cerr << "Writing birdies list to: " << birdies_file.str() << endl;

	FILE* birdies_file_pointer = fopen(birdies_file.str().c_str(),"w");

	for(Candidate c: zero_dm_candidates.cands) fprintf(birdies_file_pointer,"%.8f %.8f %.6f %d \n", 1/c.freq , c.freq, bin_width, c.assoc.size() );

	fclose(birdies_file_pointer);

}

if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after zap inits");


/**
 * Stitch and peasouping section
 * ******************************
 * Use the first filter bank to extract header information and create DM and Acceleration trial list that can
 * be reused for all stitches.
 */



vector<float> acc_list;
AccelerationPlan acc_plan(args.acc_start, args.acc_end, args.acc_tol, args.acc_pulse_width, args.size, tsamp, cfreq, foff);
acc_plan.generate_accel_list(0.0,acc_list);

vector<float> dm_list;
Dedisperser ffb_dedisperser(*ffb,1);
ffb_dedisperser.generate_dm_list(args.dm_start,args.dm_end,args.dm_pulse_width,args.dm_tol);
dm_list = ffb_dedisperser.get_dm_list();


/**
 *
 * parameters for the xml output file.
 *
 */
//stringstream xml_filename;
//xml_filename <<  args.out_dir << PATH_SEPERATOR <<  args.utc << ".xml";
//
//OutputFileWriter stats(xml_filename.str());
//stats.add_misc_info();
//stats.add_search_parameters(args);
//stats.add_dm_list(dm_list);
//stats.add_acc_list(acc_list);


//
//if(args.out_suffix !="") xml_filename<<"."<<args.out_suffix;
//
//vector<int> device_idxs;
//for (int device_idx=0;device_idx<1;device_idx++) device_idxs.push_back(device_idx);

//stats.add_gpu_info(device_idxs);
//stats.to_file(xml_filename.str());

if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after peasoup inits");


map<int, DispersionTrials<unsigned char> > dedispersed_series_map;

for(vector<int>::iterator fb_iterator = unique_fbs->begin(); fb_iterator != unique_fbs->end(); fb_iterator++){
	int fb = (int)*(fb_iterator);

	vivek::Filterbank* f = fanbeams.at(fb);

	Dedisperser dedisperser(*f,1);
	dedisperser.set_dm_list(dm_list);

	PUSH_NVTX_RANGE("Dedisperse",3)
	DispersionTrials<unsigned char> trials = dedisperser.dedisperse();
	POP_NVTX_RANGE

	dedispersed_series_map.insert(map<int, DispersionTrials<unsigned char> >::value_type(fb,trials));

	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("while dedispersion");

	delete f;


}

if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after dedispersion");


size_t max_delay = dedispersed_series_map.begin()->second.get_max_delay();
int reduced_nsamples = nsamples - max_delay;

//cerr << "nsamps: " <<nsamples << " max DM delay: " << max_delay << " Reduced samples: " << reduced_nsamples << endl;

CandidateCollection all_cands;

int point_index= 1;

DispersionTrials<unsigned char> stitched_trials = DispersionTrials<unsigned char>(ConfigManager::fft_size(),tsamp, dm_list,max_delay);

Peasoup peasoup(*ffb, args,stitched_trials, acc_plan, bzap,  all_cands);

unsigned char* previous_data = nullptr;

pthread_t current_peasoup_thread = 0;

for(UniquePoint* point: *unique_points){

	cerr<< " Processing point " <<  point_index << " / " <<  unique_points->size() << endl;

	unsigned char* data = new_and_check<unsigned char>(dm_list.size()*ConfigManager::fft_size(),"tracked data.");

	stitch_1D(dedispersed_series_map, point, ConfigManager::fft_size(), dm_list, data);


//	if(point_index !=1) {
//		cerr << "Waiting for peasoup..." << endl;
//		int join_return = pthread_join(current_peasoup_thread, NULL);
//
//		if(join_return != 0 ){
//			cerr << "Could not join previous thread. Aborting with ERR NO: " << join_return << endl;
//			exit(EXIT_FAILURE);
//		}
//
//	}


	stitched_trials.set_data(data);

	peasoup.set_point(point);

	peasoup.do_peasoup();

//	int create_return = pthread_create(&current_peasoup_thread, NULL, Peasoup::peasoup_thread, (void*) &peasoup);

	//if(ErrorChecker::check_pthread_create_error(create_return,"Peasoup thread") == EXIT_FAILURE) exit(EXIT_FAILURE);

	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("while peasouping");


	delete[] previous_data;
	previous_data = data;

	point_index++;

}

cerr << "Joining final peasoup" << endl;

//int join_return = pthread_join(current_peasoup_thread, NULL);
//
//if(join_return != 0 ){
//	cerr << "Could not join last peasoup thread. Aborting with ERR NO: " << join_return << endl;
//	exit(EXIT_FAILURE);
//}

cerr<<"cleaning up peasoup" << endl;
delete[] previous_data;

//exit(EXIT_SUCCESS);
cerr << "Done peasouping. Found "<< all_cands.cands.size() << "candidates before local coincidencing" << endl;

//for(Candidate c: all_cands.cands){
//
//	cerr << c.ra_str << " " << c.dec_str << " " << 1/c.freq << " " << c.dm << " " << c.snr <<  " " << c.folded_snr<< endl;
//
//}

DMDistiller dm_still(args.freq_tol,true);

CandidateCollection distilled_cands;
distilled_cands.cands = dm_still.distill(all_cands.cands);


cerr << "Found "<< distilled_cands.cands.size() << "candidates after local coincidencing" << endl;


cerr << "Attempting to call global coincidencer" << endl;


if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown(" before coincidencing");




coincidencer->init_this_candidates(distilled_cands);
if ( coincidencer->send_candidates_to_all_nodes() == EXIT_FAILURE){
	cerr << "Problem sending candidates to other nodes. Aborting now";
	exit(EXIT_FAILURE);
}
coincidencer->gather_all_candidates();
coincidencer->coincidence();
coincidencer->print_shortlisted_candidates();



ostringstream oss;
oss << args.candidates_dir << PATH_SEPERATOR << args.candidates_file;

FILE* fp = fopen(oss.str().c_str(),"w");
coincidencer->print_shortlisted_candidates_more(fp);

fclose(fp);

oss << ".more";

FILE* fp2 = fopen(oss.str().c_str(),"w");
coincidencer->print_shortlisted_candidates_more(fp2);

fclose(fp2);


cerr << endl << " SMIRFsouping Done for utc" << args.utc << endl;

cerr << endl << "Writing obs.processing in " << args.smirf_utc_dir << endl;


ostringstream processing_file_name;
processing_file_name << args.smirf_utc_dir << PATH_SEPERATOR << "obs.processing";

fstream processing_file;
processing_file.open(processing_file_name.str().c_str(),fstream::out);

if(!processing_file.is_open()){
	cerr << "Could not touch obs.processing. Aborting"<< endl;
	exit(EXIT_FAILURE);
}

processing_file.close();


}


void* Peasoup::peasoup_thread(void* ptr){

	Peasoup* peasoup = reinterpret_cast<Peasoup*>(ptr);
	peasoup->do_peasoup();
	pthread_exit(NULL);
}


void Peasoup::do_peasoup(){

	CandidateCollection dm_cands;

	int nthreads = 1;

	DMDispenser dispenser(trials);

	Worker* worker = new Worker(trials,dispenser,acc_plan,args,args.size, bzap, point);
	worker->start();
	dm_cands.append(worker->dm_trial_cands.cands);


	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown(" While souping");


	DMDistiller dm_still(args.freq_tol,true);
	dm_cands.cands = dm_still.distill(dm_cands.cands);

	HarmonicDistiller harm_still(args.freq_tol,args.max_harm,true,false);
	dm_cands.cands = harm_still.distill(dm_cands.cands);

	CandidateScorer cand_scorer(sample_fil.get_tsamp(),sample_fil.get_cfreq(), sample_fil.get_foff(), fabs(sample_fil.get_foff())*sample_fil.get_nchans());
	cand_scorer.score_all(dm_cands.cands);

	MultiFolder folder(dm_cands.cands,trials);

	if(args.npdmp > 0 ) {
		folder.fold_n(args.npdmp);
	}

	int new_size = min(args.limit,(int) dm_cands.cands.size());
	dm_cands.cands.resize(new_size);

	all_cands.append(dm_cands);

	delete worker;

}




void stitch_1D( map<int, DispersionTrials<unsigned char> >& dedispersed_series_map, UniquePoint* point, unsigned int reduced_nsamples, vector<float>& dm_list, unsigned char* data ){

	int ptr = 0;

	int last_traversal = point->traversals->size() - 1;
	int traversal_num = 0;


	for(vector<Traversal*>::iterator it2 = point->traversals->begin(); it2!=point->traversals->end(); it2++, traversal_num++){
		Traversal* traversal = *it2;

		int startSample = traversal->startSample;

		size_t num = (startSample+traversal->numSamples > (reduced_nsamples)) ? (reduced_nsamples - startSample) : traversal->numSamples;

		DispersionTrials<unsigned char> dedispTimeseries4FB = dedispersed_series_map.find(traversal->fanbeam)->second;

		int trialIndex = 0;

		for( int trial = 0; trial < dm_list.size(); trial++){

			DedispersedTimeSeries<unsigned char> trialTimeSeries = dedispTimeseries4FB[trial];

			unsigned char* trial_data = trialTimeSeries.get_data();

			memcpy(&data[trialIndex + ptr],&trial_data[startSample],sizeof(unsigned char)*num);

			trialIndex+= reduced_nsamples;

		}



		ptr+=num;
		if(ptr >= reduced_nsamples) break;

		if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("while stitching");

	}

}



CandidateCollection get_zero_dm_candidates(map<int,vivek::Filterbank*>* fanbeams, CmdLineOptions& args){

	vivek::Filterbank* ffb = fanbeams->begin() -> second;

	long data_bytes = ffb -> data_bytes;
	int nsamples = ffb -> get_nsamps();
	double tsamp = ffb -> get_tsamp();
	double cfreq = ffb -> get_cfreq();
	double foff =  ffb -> get_foff();
	unsigned int size = Utils::prev_power_of_two(ffb->get_nsamps());


	CandidateCollection dm_cands;

	cudaSetDevice(ConfigManager::this_gpu_device());

	CuFFTerR2C r2cfft(size);
	CuFFTerC2R c2rfft(size);

	for (map<int,vivek::Filterbank*>::iterator it=fanbeams->begin(); it!=fanbeams->end(); ++it){

		vivek::Filterbank* f  = it->second;

		Dedisperser zero_dm_dedisperser(*f,1);
		zero_dm_dedisperser.generate_dm_list(0,0,0,0);

		PUSH_NVTX_RANGE("Dedisperse zero DM",3)

		DispersionTrials<unsigned char> trials = zero_dm_dedisperser.dedisperse();

		POP_NVTX_RANGE

		if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("while getting zero DM birdies");

		DedispersedTimeSeries<unsigned char> tim;
		trials.get_idx(0,tim);

		ReusableDeviceTimeSeries<float,unsigned char> d_tim(size);
		d_tim.copy_from_host(tim);

		float tobs = size*f->tsamp;
		float bin_width = 1.0/tobs;

		DeviceFourierSeries<cufftComplex> d_fseries(size/2+1,bin_width);
		r2cfft.execute(d_tim.get_data(),d_fseries.get_data());

		DevicePowerSpectrum<float> pspec(d_fseries);

		SpectrumFormer former;
		former.form(d_fseries,pspec);

		Dereddener rednoise(size/2+1);
		rednoise.calculate_median(pspec);
		rednoise.deredden(d_fseries);
		former.form_interpolated(d_fseries,pspec);

		float mean,std,rms;
		stats::stats<float>(pspec.get_data(),size/2+1,&mean,&rms,&std);

		c2rfft.execute(d_fseries.get_data(),d_tim.get_data());

		r2cfft.execute(d_tim.get_data(),d_fseries.get_data());
		former.form_interpolated(d_fseries,pspec);

		stats::normalise(pspec.get_data(),mean*size,std*size,size/2+1);

		if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("while getting zero DM birdies");


		HarmonicSums<float> sums(pspec,args.nharmonics);
		HarmonicFolder harm_folder(sums);
		harm_folder.fold(pspec);

		SpectrumCandidates trial_cands(tim.get_dm(),0,0.0);

		PeakFinder cand_finder(args.min_snr,args.min_freq,args.max_freq,size);
		cand_finder.find_candidates(pspec,trial_cands);
		cand_finder.find_candidates(sums,trial_cands);

		HarmonicDistiller harm_finder(args.freq_tol,args.max_harm,false);
		dm_cands.append(harm_finder.distill(trial_cands.cands));

		if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("while getting zero DM birdies");

	}
	POP_NVTX_RANGE

	DMDistiller dm_still(args.freq_tol,true);

	CandidateCollection distilled_cands;
	distilled_cands.cands = dm_still.distill(dm_cands.cands);

	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown("after getting zero DM birdies");


	return distilled_cands;
}


int populate_unique_points(std::string abs_file_name, std::vector<UniquePoint*>* unique_points,std::vector<std::string>* str_points,  std::vector<int>* unique_fbs, int point_index ){

	if( !file_exists(abs_file_name) ){

		cerr << __func__ << ": Unique points file: '" << abs_file_name << "' does not exist." << endl;
		return EXIT_FAILURE;
	}

	std::string line;
	std::ifstream unique_points_file_stream(abs_file_name.c_str());
	int line_number = 0;

	max_fanbeam_traversal = 0;

	if(unique_points_file_stream.is_open()){
		while(getline(unique_points_file_stream, line)){
			line_number++;
			if(point_index != -1  && point_index != line_number) continue;

			str_points->push_back(line);
			UniquePoint* point = new UniquePoint();
			std::vector<std::string> vstrings = split(line,' ');

			point->ra = vstrings.at(POINT_RA);
			point->num = line_number -1;
			point->dec = vstrings.at(POINT_DEC);

			point->startFanbeam =atof(vstrings.at(POINT_START_FANBEAM).c_str());
			point->endFanbeam = atof(vstrings.at(POINT_END_FANBEAM).c_str());

			point->startNS =atof(vstrings.at(POINT_START_NS).c_str());
			point->endNS = atof(vstrings.at(POINT_END_NS).c_str());

			for(std::vector<std::string>::size_type i = TRAVERSAL_START_INDEX ; i != vstrings.size(); i = i + TRAVERSAL_SIZE) {

				std::string value = vstrings[i];
				Traversal* t = new Traversal(&vstrings[i]);
				point->traversals->push_back(t);
				if(std::find(unique_fbs->begin(), unique_fbs->end(),(int)t->fanbeam)== unique_fbs->end()) unique_fbs->push_back((int)t->fanbeam);
			}

			if(point->traversals->size() > max_fanbeam_traversal ) max_fanbeam_traversal = point->traversals->size();

			unique_points->push_back(point);
		}
		unique_points_file_stream.close();
	}

	return EXIT_SUCCESS;

}



//int transfer_to_shared_memory(void* ptr){
//	vivek::Filterbank* stitched_filterbank = reinterpret_cast<vivek::Filterbank*>(ptr);
//	vivek::Archiver* a = new vivek::Archiver();
//	a->transfer_fil_to_DADA_buffer(stitched_filterbank,false);
//	return EXIT_SUCCESS;
//
//}

void* launch_worker_thread(void* ptr){
	reinterpret_cast<Worker*>(ptr)->start();
	return NULL;
}


void Worker::start(void)
{

	cudaSetDevice(ConfigManager::this_gpu_device());
	Stopwatch pass_timer;
	pass_timer.start();

	bool padding = false;
	if (size > trials.get_nsamps())
		padding = true;

	CuFFTerR2C r2cfft(size);
	CuFFTerC2R c2rfft(size);
	float tobs = size*trials.get_tsamp();
	float bin_width = 1.0/tobs;
	DeviceFourierSeries<cufftComplex> d_fseries(size/2+1,bin_width);
	DedispersedTimeSeries<unsigned char> tim;
	ReusableDeviceTimeSeries<float,unsigned char> d_tim(size);
	DeviceTimeSeries<float> d_tim_r(size);
	TimeDomainResampler resampler;
	DevicePowerSpectrum<float> pspec(d_fseries);

	Dereddener rednoise(size/2+1);
	SpectrumFormer former;
	PeakFinder cand_finder(args.min_snr,args.min_freq,args.max_freq,size);
	HarmonicSums<float> sums(pspec,args.nharmonics);
	HarmonicFolder harm_folder(sums);
	std::vector<float> acc_list;
	HarmonicDistiller harm_finder(args.freq_tol,args.max_harm,false);
	AccelerationDistiller acc_still(tobs,args.freq_tol,true);
	float mean,std,rms;
	float padding_mean;
	int ii;

	PUSH_NVTX_RANGE("DM-Loop",0)
	while (true){
		ii = manager.get_dm_trial_idx();

		if (ii==-1)
			break;
		trials.get_idx(ii,tim);

		if (args.verbose)
			std::cout << "Copying DM trial to device (DM: " << tim.get_dm() << ")"<< std::endl;

		d_tim.copy_from_host(tim);

		//timers["rednoise"].start()
		if (padding){
			padding_mean = stats::mean<float>(d_tim.get_data(),trials.get_nsamps());
			d_tim.fill(trials.get_nsamps(),d_tim.get_nsamps(),padding_mean);
		}

		if (args.verbose)
			std::cerr << "Generating accelration list" << std::endl;
		acc_plan.generate_accel_list(tim.get_dm(),acc_list);

		if (args.verbose)
			std::cerr << "Searching "<< acc_list.size()<< " acceleration trials for DM "<< tim.get_dm() << std::endl;

		if (args.verbose)
			std::cerr << "Executing forward FFT" << std::endl;
		r2cfft.execute(d_tim.get_data(),d_fseries.get_data());

		if (args.verbose)
			std::cerr << "Forming power spectrum" << std::endl;
		former.form(d_fseries,pspec);

		if (args.verbose)
			std::cerr << "Finding running median" << std::endl;
		rednoise.calculate_median(pspec);

		if (args.verbose)
			std::cerr << "Dereddening Fourier series" << std::endl;
		rednoise.deredden(d_fseries);

		//		cerr << "bzap" << (bzap == NULL) << endl;

		if (bzap){

			if (args.verbose)
				std::cerr << "Zapping birdies" << std::endl;

			bzap->zap(d_fseries);
		}


		if (args.verbose)
			std::cerr << "Forming interpolated power spectrum" << std::endl;
		former.form_interpolated(d_fseries,pspec);

		if (args.verbose)
			std::cerr << "Finding statistics" << std::endl;
		stats::stats<float>(pspec.get_data(),size/2+1,&mean,&rms,&std);

		if (args.verbose)
			std::cerr << "Executing inverse FFT" << std::endl;
		c2rfft.execute(d_fseries.get_data(),d_tim.get_data());

		CandidateCollection accel_trial_cands;
		PUSH_NVTX_RANGE("Acceleration-Loop",1)

		for (int jj=0;jj<acc_list.size();jj++){
			if (args.verbose)
				std::cerr << "Resampling to "<< acc_list[jj] << " m/s/s" << std::endl;
			resampler.resampleII(d_tim,d_tim_r,size,acc_list[jj]);

			if (args.verbose)
				std::cerr << "Execute forward FFT" << std::endl;
			r2cfft.execute(d_tim_r.get_data(),d_fseries.get_data());

			if (args.verbose)
				std::cerr << "Form interpolated power spectrum" << std::endl;
			former.form_interpolated(d_fseries,pspec);

			if (args.verbose)
				std::cerr << "Normalise power spectrum" << std::endl;
			stats::normalise(pspec.get_data(),mean*size,std*size,size/2+1);

			if (args.verbose)
				std::cerr << "Harmonic summing" << std::endl;
			harm_folder.fold(pspec);

			if (args.verbose)
				std::cerr << "Finding peaks" << std::endl;
			SpectrumCandidates trial_cands(tim.get_dm(),ii,acc_list[jj]);



			if (args.verbose)
				std::cerr << "SpectrumCandidates" << std::endl;
			cand_finder.find_candidates(pspec,trial_cands);
			if (args.verbose)
				std::cerr << "after pspec" << sums.size() << std::endl;
			cand_finder.find_candidates(sums,trial_cands);



			CandidateCollection updated_candidates;

			for(Candidate c: trial_cands.cands){

				c.ra_str = point->ra;
				c.dec_str = point->dec;

				c.start_fanbeam = point->startFanbeam;
				c.start_ns = point->startNS;

				updated_candidates.append(c);
			}

			if (args.verbose)
				std::cerr << "Distilling harmonics" << std::endl;
			accel_trial_cands.append(harm_finder.distill(updated_candidates.cands));

			if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown(" While souping");

		}
		POP_NVTX_RANGE
		if (args.verbose)
			std::cerr << "Distilling accelerations" << std::endl;
		dm_trial_cands.append(acc_still.distill(accel_trial_cands.cands));
	}
	POP_NVTX_RANGE


	if (args.verbose)
		std::cerr << "DM processing took " << pass_timer.getTime() << " seconds"<< std::endl;
}



//int peasoup_multi(vivek::Filterbank* fil,CmdLineOptions& args, DispersionTrials<unsigned char>& trials, OutputFileWriter& stats,
//		AccelerationPlan& acc_plan, Zapper* bzap, int pt_num, UniquePoint* point, int candidate_id, CandidateCollection* all_cands){
//
//	CandidateCollection dm_cands  = peasoup(fil,args,trials,acc_plan,bzap,point);
//
//	string name = get_candidate_file_name(args.out_dir, -1, args.host );
//
//	stats.add_candidates(dm_cands.cands,pt_num,point->ra,point->dec);
//
////	FILE* fp;
////
////	if(file_open(&fp, name.c_str(),"a")  == EXIT_FAILURE){
////		cerr << "Problem opening candidate file for writing / appending." << endl;
////	}
////
////	dm_cands.print_cand_file(fp, candidate_id);
////
////	fclose(fp);
//
//	stats.to_file();
//
//
//	all_cands->append(dm_cands);
//
//	return dm_cands.cands.size();
//
//
//}





//CandidateCollection peasoup(vivek::Filterbank* fil, CmdLineOptions& args, DispersionTrials<unsigned char>& trials, AccelerationPlan& acc_plan,
//		Zapper* bzap, UniquePoint* point) {
//
//	CandidateCollection dm_cands;
//
//	int nthreads = 1;
//
//	DMDispenser dispenser(trials);
//
//	Worker* worker = new Worker(trials,dispenser,acc_plan,args,args.size, bzap, point);
//	worker->start();
//	dm_cands.append(worker->dm_trial_cands.cands);
//
//	if( ShutdownManager::shutdown_called() ) ShutdownManager::shutdown(" While souping");
//
//
//	DMDistiller dm_still(args.freq_tol,true);
//	dm_cands.cands = dm_still.distill(dm_cands.cands);
//
//	HarmonicDistiller harm_still(args.freq_tol,args.max_harm,true,false);
//	dm_cands.cands = harm_still.distill(dm_cands.cands);
//
//	CandidateScorer cand_scorer(fil->get_tsamp(),fil->get_cfreq(), fil->get_foff(), fabs(fil->get_foff())*fil->get_nchans());
//	cand_scorer.score_all(dm_cands.cands);
//
//	MultiFolder folder(dm_cands.cands,trials);
//
//	if(args.npdmp > 0 ) {
//		folder.fold_n(args.npdmp);
//	}
//
//	int new_size = min(args.limit,(int) dm_cands.cands.size());
//	dm_cands.cands.resize(new_size);
//
//	delete worker;
//
//	return dm_cands;
//
//
//
//}
















//int peasoup_multi2(vivek::Filterbank* filobj,CmdLineOptions& args, DispersionTrials<unsigned char>& trials, OutputFileWriter& stats,
//		string xml_filename, AccelerationPlan& acc_plan, int pt_num, string pt_ra, string pt_dec){
//	map<string,Stopwatch> timers;
//
//
//	string birdiefile = "";
//
//	int nthreads = 1;
//
//	unsigned int size;
//	if (args.size==0) size = Utils::prev_power_of_two(filobj->get_nsamps());
//	else size = args.size;
//	if (args.verbose)
//		cout << "Setting transform length to " << size << " points" << endl;
//
//
//	//Multithreading commands
//	vector<Worker*> workers(nthreads);
//	vector<pthread_t> threads(nthreads);
//	cerr<< "dispensing trials"<<endl;
//	DMDispenser dispenser(trials);
//	if (args.progress_bar)
//		dispenser.enable_progress_bar();
//	cerr<< "starting  workers"<<endl;
//	for (int ii=0;ii<nthreads;ii++){
//		workers[ii] = (new Worker(trials,dispenser,acc_plan,args,size,ii));
//		pthread_create(&threads[ii], NULL, launch_worker_thread, (void*) workers[ii]);
//	}
//	//	Worker* worker = new Worker(trials,dispenser,acc_plan,args,size,0);
//	//	worker->start();
//
//	DMDistiller dm_still(args.freq_tol,true);
//	HarmonicDistiller harm_still(args.freq_tol,args.max_harm,true,false);
//	CandidateCollection dm_cands;
//	for (int ii=0; ii<nthreads; ii++){
//		pthread_join(threads[ii],NULL);
//		dm_cands.append(workers[ii]->dm_trial_cands.cands);
//	}
//	//dm_cands.append(worker->dm_trial_cands.cands);
//
//	if (args.verbose)
//		cout << "Distilling DMs" << endl;
//
//
//	dm_cands.cands = dm_still.distill(dm_cands.cands);
//	dm_cands.cands = harm_still.distill(dm_cands.cands);
//
//	CandidateScorer cand_scorer(filobj->get_tsamp(),filobj->get_cfreq(), filobj->get_foff(),
//			fabs(filobj->get_foff())*filobj->get_nchans());
//	cand_scorer.score_all(dm_cands.cands);
//
//	if (args.verbose)
//		cout << "Setting up time series folder" << endl;
//
//	MultiFolder folder(dm_cands.cands,trials);
//	if (args.progress_bar)
//		folder.enable_progress_bar();
//
//	if (args.npdmp > 0){
//		if (args.verbose)
//			cout << "Folding top "<< args.npdmp <<" cands" << endl;
//		folder.fold_n(args.npdmp);
//	}
//
//	if (args.verbose)
//		cout << "Writing output files" << endl;
//	//dm_cands.write_candidate_file("./old_cands.txt");
//
//	cerr << "num candidates:" << dm_cands.cands.size() << endl;
//
//	int new_size = min(args.limit,(int) dm_cands.cands.size());
//	dm_cands.cands.resize(new_size);
//
//	stringstream name_stream;
//	name_stream <<pt_ra << pt_dec << ".cand";
//	string out = name_stream.str();
//
//	stats.add_candidates(dm_cands.cands,pt_num,pt_ra,pt_dec);
//
//	FILE* fp = fopen(out.c_str(),"w");
//
//	fprintf(fp,"# RA: %s DEC: %s \n",pt_ra.c_str(),pt_dec.c_str());
//
//
//	dm_cands.print_cand_file(fp,pt_ra.c_str(),pt_dec.c_str(), 0);
//	fclose(fp);
//
//	//stats.add_timing_info(timers);
//
//	stats.to_file(xml_filename);
//	for (vector< Worker* >::iterator it = workers.begin() ; it != workers.end(); ++it) delete (*it);
//	workers.clear();
//	//delete worker;
//	return 0;
//}
//
