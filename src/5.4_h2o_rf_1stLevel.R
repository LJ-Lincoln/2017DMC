#This script is to train a random forest model at the first level  
# to classify whether the product is ordered or not.
#
#Inputs: 
#     train_set(1<=day<=77): file from the path 'data/processed/train_set.feather'
#     pesudo_test_set(78<=day<=92): file from the path 'data/processed/validation_set.feather'
#Outputs: 
#     rf-*modelid*-*auc*: save the h2o models in the folder 'models/'
#     rf-*modelid*-1stLevelPred.csv: the prediction on the untouched test set


library(feather)
library(h2o)
library(data.table)
library(stringr)
#library(h2oEnsemble)

h2o.init(nthreads = 36, #Number of threads -1 means use all cores on your machine
         enable_assertions = FALSE)  #max mem size is the maximum memory to allocate to H2O

h2o.removeAll()

####################################################################
### Set-up the validation scheme                                 ###
####################################################################

train63d <- read_feather("../data/processed/end63_train.feather")
valid63d <- read_feather("../data/processed/end63_test.feather")

# define predictors
features <- fread("../data/processed/feature_list.csv")
#treat day_mod_ features as categorical
features[str_detect(name,'day_mod_'),type := "categorical"]
#should not include them in the modeling
NOT_USE <- c("pid", "fold", "lineID", "deduplicated_pid")
#not useful features list
LESS_IMPORTANT_VARS <- c("category_is_na","campaignIndex_is_na",
                         "pharmForm_is_na", "content_part1", 
                         "content_part2", "content_part3", 
                         "total_units", "price_discount_p25",
                         "price_discount_p75")

cat_vars <-  setdiff(features[type == "categorical", name], c(NOT_USE, LESS_IMPORTANT_VARS))
cont_vars <- setdiff(features[type == "numeric", name], c(cat_vars, LESS_IMPORTANT_VARS))

#probably want to replace these features
HIGH_DIMENSION_VARS <- c("group", "content", "manufacturer", 
                         "category", "pharmForm")
REPLACE_HIGH_DIMENSION_VARS <- FALSE
if (REPLACE_HIGH_DIMENSION_VARS == TRUE){
  cat_vars <- setdiff(cat_vars, HIGH_DIMENSION_VARS)
}

label <- c("order", "order_qty")
all_preds <- c(cat_vars, cont_vars)
all_vars <- c(all_preds, label)

train_set.hex <- as.h2o(train63d[all_vars])
validation_set.hex <- as.h2o(valid63d[all_vars])
rm(train63d, valid63d)

# factorize the categorical variables
for (c in cat_vars) {
  train_set.hex[c] <- as.factor(train_set.hex[c])
}

for (c in cat_vars) {
  validation_set.hex[c] <- as.factor(validation_set.hex[c])
}

####################################################################
### modeling part - Grid Search                                 ###
####################################################################

# random forest hyperparamters
rf_params <- list( max_depth = seq(5, 13, 1),
                   sample_rate = seq(0.5, 1.0, 0.1),
                   #min_rows = c(2,4,6),
                   col_sample_rate_change_per_level = seq(0.5, 2.0, 0.2),
                   ## search a large space of column sampling rates per tree
                   col_sample_rate_per_tree = seq(0.5, 1, 0.1), 
                   ## search a few minimum required relative error improvement thresholds for a split to happen
                   min_split_improvement = c(0,1e-8,1e-6,1e-4),
                   ## try all histogram types (QuantilesGlobal and RoundRobin are good for numeric columns with outliers)
                   histogram_type = c("UniformAdaptive","QuantilesGlobal","RoundRobin"))
# Random Grid Search

search_criteria <- list(strategy = "RandomDiscrete", 
                        # train no more than 10 models
                        max_models = 8,
                        ## random number generator seed to make sampling of parameter combinations reproducible
                        seed = 1234,                        
                        ## early stopping once the leaderboard of the top 5 models is 
                        #converged to 0.1% relative difference
                        stopping_rounds = 5,                
                        stopping_metric = "AUC",
                        stopping_tolerance = 1e-3)

# Train and validate a grid of RFs for parameter tuning
rf_grid <- h2o.grid(algorithm = "randomForest",
                    hyper_params = rf_params,
                    search_criteria = search_criteria,
                    x = all_preds, 
                    y = "order",
                    grid_id = "rf_grid",
                    training_frame = train_set.hex,
                    validation_frame = validation_set.hex,
                    ntrees = 1000,
                    ## early stopping once the validation AUC doesn't improve 
                    #by at least 0.01% for 5 consecutive scoring events
                    stopping_rounds = 5, 
                    stopping_tolerance = 1e-4,
                    stopping_metric = "AUC", 
                    score_tree_interval = 10,
                    seed = 27)

sorted_RF_Grid <- h2o.getGrid(grid_id = "rf_grid", 
                              sort_by = "auc", 
                              decreasing = TRUE)
print(sorted_RF_Grid)
#save the top 3 models and generate the prediction features on 1-63d and 64-77d
for (i in 1:3){
  rf <- h2o.getModel(sorted_RF_Grid@model_ids[[i]])
  h2o.saveModel(rf, paste("../models/1stLevel/h2o_rf",i), force=TRUE)
  preds_train63d <- as.data.frame(h2o.predict(rf, train_set.hex))[,3]
  preds_test63d <- as.data.frame(h2o.predict(rf, validation_set.hex))[,3]
  preds_train63d <- cbind(train63d_index_df, preds_train63d)
  preds_valid63d <- cbind(valid63d_index_df, preds_test63d)
  write_feather(preds_train63d, paste0("../data/preds1stLevel/end63d_train_rf",i,'.feather'))
  write_feather(preds_valid63d, paste0("../data/preds1stLevel/end63d_test_rf",i,'.feather'))
}

train63d_index_df <- train63d[c("lineID")]
valid63d_index_df <- valid63d[c("lineID")]



#rf_models <- lapply(rf_grid@model_ids, function(model_id) h2o.getModel(model_id))

####################################################################
### Retain the model on train77d                                 ###
####################################################################
#Load train77d and test77d dataset
train77d <- read_feather("../data/processed/end77_train.feather")
test77d <- read_feather("../data/processed/end77_test.feather")

train77d_index_df <- train77d[c("lineID")]
test77d_index_df <- test77d[c("lineID")]

#Load into the h2o environment
retrain_set.hex <- as.h2o(train77d[all_vars])
test_set.hex <- as.h2o(test77d[all_preds])
# factorize the categorical variables
for(c in cat_vars){
  retrain_set.hex[c] <- as.factor(retrain_set.hex[c])
}

for(c in cat_vars){
  test_set.hex[c] <- as.factor(test_set.hex[c])
}
rm(train77d, test77d)  

# Only choose the top 3 models and persist the retrained model
# Note: need to refit model including the pesudo validation set
for (i in 1:3) {
  rf <- h2o.getModel(sorted_RF_Grid@model_ids[[i]])
  retrained_rf <- do.call(h2o.randomForest,
                          ## update parameters in place
                          {
                            p <- rf@parameters  # the same seed
                            p$model_id = NULL          ## do not overwrite the original grid model
                            p$training_frame = retrain_set.hex   ## use the full training dataset
                            p$validation_frame = NULL  ## no validation frame
                            p
                          }
  )
  print(rf@model_id)
  ## Get the AUC on the hold-out test set
  retrained_rf_auc <- round(h2o.auc(h2o.performance(retrained_rf, newdata = test_set.hex)),4)
  preds_train77d <- as.data.frame(h2o.predict(retrained_rf, retrain_set.hex))[,3]
  preds_test77d <- as.data.frame(h2o.predict(retrained_rf, test_set.hex))[,3]
  preds_train77d <- cbind(train77d_index_df, preds_train77d)
  preds_test77d <- cbind(test77d_index_df, preds_test77d)
  newnames = paste("preds_rf",i,sep="")
  names(preds_train77d)[2] = newnames
  names(preds_test77d)[2] = newnames
  
  # save the retrained model to regenerate the predictions for 2nd level modeling 
  # and possibly useful for ensemble
  h2o.saveModel(retrained_rf, paste("../models/1stLevel/h2o_rf",retrained_rf_auc,sep = '-'), force = TRUE)
  write_feather(preds_train77d, paste0("../data/preds1stLevel/end77d_train_rf",retrained_rf_auc,'.feather'))
  write_feather(preds_test77d, paste0("../data/preds1stLevel/end77d_test_rf",retrained_rf_auc,'.feather'))
}


####################################################################
### Retain the model on train92d                                 ###
####################################################################
#Load train92d and test92d dataset
train92d <- read_feather("../data/processed/end92_train.feather")
test92d <- read_feather("../data/processed/end92_test.feather")

train92d_index_df <- train92d[c("lineID")]
test92d_index_df <- test92d[c("lineID")]

#Load into the h2o environment
retrain_set.hex <- as.h2o(train92d[all_vars])
test_set.hex <- as.h2o(test92d[all_vars])
# factorize the categorical variables
for(c in cat_vars){
  retrain_set.hex[c] <- as.factor(retrain_set.hex[c])
}

for(c in cat_vars){
  test_set.hex[c] <- as.factor(test_set.hex[c])
}
rm(train92d, test92d)  

# Only choose the top 3 models and persist the retrained model
# Note: need to refit model including the pesudo validation set
for (i in 1:3) {
  rf <- h2o.getModel(sorted_RF_Grid@model_ids[[i]])
  retrained_rf <- do.call(h2o.randomForest,
                          ## update parameters in place
                          {
                            p <- rf@parameters  # the same seed
                            p$model_id = NULL          ## do not overwrite the original grid model
                            p$training_frame = retrain_set.hex   ## use the full training dataset
                            p$validation_frame = NULL  ## no validation frame
                            p
                          }
  )
  print(rf@model_id)
  ## Get the AUC on the hold-out test set
  retrained_rf_auc <- round(h2o.auc(h2o.performance(retrained_rf, newdata = test_set.hex)),4)
  preds_train92d <- as.data.frame(h2o.predict(retrained_rf, retrain_set.hex))[,3]
  preds_test92d <- as.data.frame(h2o.predict(retrained_rf, test_set.hex))[,3]
  preds_train92d <- cbind(train92d_index_df, preds_train92d)
  preds_test92d <- cbind(test92d_index_df, preds_test92d)
  newnames = paste("preds_rf",i,sep="")
  names(preds_train92d)[2] = newnames
  names(preds_test92d)[2] = newnames
  
  # save the retrained model to regenerate the predictions for 2nd level modeling 
  # and possibly useful for ensemble
  h2o.saveModel(retrained_rf, paste("../models/1stLevel/h2o_rf",retrained_rf_auc,sep = '-'), force = TRUE)
  write_feather(preds_train92d, paste0("../data/preds1stLevel/end92d_train_rf",retrained_rf_auc,'.feather'))
  write_feather(preds_test92d, paste0("../data/preds1stLevel/end92d_test_rf",retrained_rf_auc,'.feather'))
}
h2o.shutdown(prompt = FALSE)
