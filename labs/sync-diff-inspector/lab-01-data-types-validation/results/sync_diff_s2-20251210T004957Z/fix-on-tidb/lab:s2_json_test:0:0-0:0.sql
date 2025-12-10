-- table: lab.s2_json_test
-- range in sequence: Full
/*
  DIFF COLUMNS ╏           `JSON COL`            
╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╋╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
  source data  ╏ '{"city": "åŒ—äº¬", "name":     
               ╏ "æŽæ˜Ž"}'                       
╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╋╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
  target data  ╏ '{"city": "北京", "name":       
               ╏ "李明"}'                        
╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╋╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
*/
REPLACE INTO `lab`.`s2_json_test`(`id`,`json_col`,`description`) VALUES (8,'{"city": "åŒ—äº¬", "name": "æŽæ˜Ž"}','Object with UTF-8');
