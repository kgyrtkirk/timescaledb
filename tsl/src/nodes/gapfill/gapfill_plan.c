/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */

#include <postgres.h>
#include <nodes/execnodes.h>
#include <nodes/extensible.h>
#include <nodes/nodeFuncs.h>
#include <optimizer/clauses.h>
#include <optimizer/optimizer.h>
#include <optimizer/pathnode.h>
#include <optimizer/paths.h>
#include <optimizer/tlist.h>
#include <utils/lsyscache.h>
#include <parser/parse_func.h>

#include "compat/compat.h"

#include "gapfill.h"
#include "gapfill_internal.h"

static CustomScanMethods gapfill_plan_methods = {
	.CustomName = "GapFill",
	.CreateCustomScanState = gapfill_state_create,
};

typedef struct gapfill_walker_context
{
	union
	{
		Node *node;
		Expr *expr;
		FuncExpr *func;
		WindowFunc *window;
	} call;
	int count;
} gapfill_walker_context;

/*
 * FuncExpr is time_bucket_gapfill function call
 */
static inline bool
is_gapfill_function_call(FuncExpr *call)
{
	char *func_name = get_func_name(call->funcid);
	return strncmp(func_name, GAPFILL_FUNCTION, NAMEDATALEN) == 0;
}

/*
 * FuncExpr is locf function call
 */
static inline bool
is_locf_function_call(FuncExpr *call)
{
	char *func_name = get_func_name(call->funcid);
	return strncmp(func_name, GAPFILL_LOCF_FUNCTION, NAMEDATALEN) == 0;
}
/*
 * FuncExpr is interpolate function call
 */
static inline bool
is_interpolate_function_call(FuncExpr *call)
{
	char *func_name = get_func_name(call->funcid);
	return strncmp(func_name, GAPFILL_INTERPOLATE_FUNCTION, NAMEDATALEN) == 0;
}

/*
 * FuncExpr is locf or interpolate function call
 */
static inline bool
is_marker_function_call(FuncExpr *call)
{
	return is_locf_function_call(call) || is_interpolate_function_call(call);
}

/*
 * Find time_bucket_gapfill function call
 */
static bool
gapfill_function_walker(Node *node, gapfill_walker_context *context)
{
	if (node == NULL)
		return false;

	if (IsA(node, FuncExpr) && is_gapfill_function_call(castNode(FuncExpr, node)))
	{
		context->call.node = node;
		context->count++;
	}

	return expression_tree_walker((Node *) node, gapfill_function_walker, context);
}

/*
 * Check if the given expression contains call to time_bucket_gapfill
 */
bool
gapfill_in_expression(Expr *node)
{
	gapfill_walker_context context = { .call.node = NULL, .count = 0 };

	gapfill_function_walker((Node *) node, &context);

	return context.count > 0;
}

/*
 * Find locf/interpolate function call
 */
static bool
marker_function_walker(Node *node, gapfill_walker_context *context)
{
	if (node == NULL)
		return false;

	if (IsA(node, FuncExpr) && is_marker_function_call(castNode(FuncExpr, node)))
	{
		context->call.node = node;
		context->count++;
	}

	return expression_tree_walker((Node *) node, marker_function_walker, context);
}

/*
 * Find window function calls
 */
static bool
window_function_walker(Node *node, gapfill_walker_context *context)
{
	if (node == NULL)
		return false;

	if (IsA(node, WindowFunc))
	{
		context->call.node = node;
		context->count++;
	}

	return expression_tree_walker(node, window_function_walker, context);
}

/*
 * check if ordering matches the order we need:
 * all groups need to be part of order
 * pathkeys must consist of group elements only
 * last element of pathkeys needs to be time_bucket_gapfill ASC
 */
static bool
gapfill_correct_order(PlannerInfo *root, Path *subpath, FuncExpr *func)
{
	if (list_length(subpath->pathkeys) != list_length(root->group_pathkeys))
		return false;

	if (list_length(subpath->pathkeys) > 0)
	{
		PathKey *pk = llast(subpath->pathkeys);
		EquivalenceMember *em = linitial(pk->pk_eclass->ec_members);

		/* time_bucket_gapfill is last element */
		if (BTLessStrategyNumber == pk->pk_strategy && IsA(em->em_expr, FuncExpr) &&
			((FuncExpr *) em->em_expr)->funcid == func->funcid)
		{
			ListCell *lc;

			/* check all groups are part of subpath pathkeys */
			foreach (lc, root->group_pathkeys)
			{
				if (!list_member(subpath->pathkeys, lfirst(lc)))
					return false;
			}
			return true;
		}
	}

	return false;
}

/* Create a gapfill plan node in the form of a CustomScan node. The
 * purpose of this plan node is to insert tuples for missing groups.
 *
 * Note that CustomScan nodes cannot be extended (by struct embedding) because
 * they might be copied, therefore we pass any extra info in the custom_private
 * field.
 *
 * The gapfill plan takes the original Agg node and imposes itself on top of the
 * Agg node. During execution, the gapfill node will produce the new tuples.
 */
static Plan *
gapfill_plan_create(PlannerInfo *root, RelOptInfo *rel, CustomPath *path, List *tlist,
					List *clauses, List *custom_plans)
{
	GapFillPath *gfpath = (GapFillPath *) path;
	CustomScan *cscan = makeNode(CustomScan);
	List *args = list_copy(gfpath->func->args);

	cscan->scan.scanrelid = 0;
	cscan->scan.plan.targetlist = tlist;
	cscan->custom_plans = custom_plans;
	
	cscan->custom_scan_tlist = ((Plan*)custom_plans->elements[0].ptr_value)->targetlist;
	cscan->flags = path->flags;
	cscan->methods = &gapfill_plan_methods;

	cscan->custom_private =
		lappend(list_make5(gfpath->func, root->parse->groupClause, root->parse->jointree, args,gfpath->subpath_column_types), gfpath->gapfill_column_types);

	return &cscan->scan.plan;
}

static CustomPathMethods gapfill_path_methods = {
	.CustomName = "GapFill",
	.PlanCustomPath = gapfill_plan_create,
};

static bool
gapfill_expression_walker(Expr *node, bool (*walker)(Node *, gapfill_walker_context *),
						  gapfill_walker_context *context)
{
	context->count = 0;
	context->call.node = NULL;

	return (*walker)((Node *) node, context);
}

/*
 * Build expression lists for the gapfill node and the node below.
 * All marker functions will be top-level function calls in the
 * resulting gapfill node targetlist and will not be included in
 * the subpath expression list
 */
static void
gapfill_build_pathtarget(PathTarget *pt_upper, PathTarget *pt_path, PathTarget *pt_subpath)
{
	ListCell *lc;
	int i = -1;

	foreach (lc, pt_upper->exprs)
	{
		Expr *expr = lfirst(lc);
		gapfill_walker_context context;
		i++;

		/* check for locf/interpolate calls */
		gapfill_expression_walker(expr, marker_function_walker, &context);
		if (context.count > 1)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("multiple interpolate/locf function calls per resultset column not "
							"supported")));

		if (context.count == 1)
		{
			/*
			 * marker needs to be toplevel for now unless we have a projection capable
			 * node above gapfill node
			 */
			if (expr != context.call.expr && !contain_window_function((Node *) expr))
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("%s must be toplevel function call",
								get_func_name(context.call.func->funcid))));

			/* if there is an aggregation it needs to be a child of the marker function */
			if (contain_agg_clause((Node *) expr) &&
				!contain_agg_clause(linitial(context.call.func->args)))
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("aggregate functions must be below %s",
								get_func_name(context.call.func->funcid))));

			if (contain_window_function(context.call.node))
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("window functions must not be below %s",
								get_func_name(context.call.func->funcid))));

			add_column_to_pathtarget(pt_path, context.call.expr, pt_upper->sortgrouprefs[i]);
			add_column_to_pathtarget(pt_subpath,
									 linitial(context.call.func->args),
									 pt_upper->sortgrouprefs[i]);
			continue;
		}

		/* check for plain window function calls without locf/interpolate */
		gapfill_expression_walker(expr, window_function_walker, &context);
		if (context.count > 1)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("multiple window function calls per column not supported")));

		if (context.count == 1)
		{
			/*
			 * window functions without arguments like rank() don't need to
			 * appear in the target list below WindowAgg node
			 */
			if (context.call.window->args != NIL)
			{
				ListCell *lc_arg;

				/*
				 * check arguments past first argument dont have Vars
				 */
				for (lc_arg = lnext_compat(context.call.window->args,
										   list_head(context.call.window->args));
					 lc_arg != NULL;
					 lc_arg = lnext_compat(context.call.window->args, lc_arg))
				{
					if (contain_var_clause(lfirst(lc_arg)))
						ereport(ERROR,
								(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
								 errmsg("window functions with multiple column "
										"references not supported")));
				}

				// makeVar

				if (contain_var_clause(linitial(context.call.window->args)))
				{
					add_column_to_pathtarget(pt_path,
											 linitial(context.call.window->args),
											 pt_upper->sortgrouprefs[i]);
					add_column_to_pathtarget(pt_subpath,
											 linitial(context.call.window->args),
											 pt_upper->sortgrouprefs[i]);
				}
			}
		}
		else
		{
			/*
			 * no locf/interpolate or window functions found so we can
			 * use expression verbatim
			 */
			// if (i < 2)
			{
				int asd = 1;
				add_column_to_pathtarget(pt_path, expr, pt_upper->sortgrouprefs[i]);
				add_column_to_pathtarget(pt_subpath, expr, pt_upper->sortgrouprefs[i]);
			}
		}
	}
}

typedef struct x_filler_context2
{
	PathTarget *project_cols;
	PathTarget *aggregate_cols;
	Index sortgroupref;
	
	List*	subpath_column_types;
	List*	gapfill_column_types;

} x_filler_context2;

#include <nodes/makefuncs.h>

static Node *
x_walker(Node *node, x_filler_context2 *ctx)
{
	if (node == NULL)
		return NULL;
	// FIXME: real group columns?!
	if (IsA(node, Var) || IsA(node, Aggref))
	{
		GapFillColumnState gfstate;
		// add_new_column_to_pathtarget(ctx->aggregate_cols, node);
		if(IsA(node, Var))
			ctx->subpath_column_types=lappend_int(ctx->subpath_column_types, GROUP_COLUMN);
			else 
			ctx->subpath_column_types=lappend_int(ctx->subpath_column_types, NULL_COLUMN);
		add_column_to_pathtarget(ctx->aggregate_cols, node, ctx->sortgroupref);
		return node;
	}
	if (IsA(node, FuncExpr)) {
		FuncExpr *expr=castNode(FuncExpr, node);
		if(is_gapfill_function_call(expr)) {
			
			// must be toplevel; and sort+group
			Assert(ctx->sortgroupref>0);

			// use aggregate to compute the normal gapfill groups
			ctx->subpath_column_types=lappend_int(ctx->subpath_column_types, TIME_COLUMN);
			add_column_to_pathtarget(ctx->aggregate_cols, copyObject(expr), ctx->sortgroupref);
			// make an extra nesting of gapfill() to have a separate version for CustomScan to process
			// FIXME: a shallow copy would suffice			
			// FuncExpr *newExpr=copyObject(expr);
			// lsecond(newExpr->args)=expr;
			// // newExpr->funcid=-123;
			return expr;
		}
		if(is_marker_function_call(expr)) {
			
			// add_new_column_to_pathtarget(ctx->aggregate_cols,
									//  linitial(expr->args));
			// add_column_to_pathtarget(ctx->aggregate_cols,
			// 						 linitial(expr->args),
			// 						 0);
			
			if(is_locf_function_call(expr)) {
			ctx->subpath_column_types=lappend_int(ctx->subpath_column_types, LOCF_COLUMN);
			}else {
			ctx->subpath_column_types=lappend_int(ctx->subpath_column_types, INTERPOLATE_COLUMN);
			}
			add_column_to_pathtarget(ctx->aggregate_cols,
									 linitial(expr->args),
									 ctx->sortgroupref);

			// add_column_to_pathtarget(ctx->aggregate_cols, node, ctx->sortgroupref);
			return node;
		}
	}

	// not valid to sort below top
	ctx->sortgroupref = 0;
	return expression_tree_mutator(node, x_walker, ctx);
}

/*
 * Decomposes a path expression into a project + aggregates.
 *
 * Example:
 * 	from:		col_1,min(col_33),case when true then min(col_99) else max(col_88) end,col_2
 *  project:	col_1,col_2,case when true then col_3 else col_4 end,col_5
 *  aggregate:	col_1,min(col_33),min(col_99),max(col_88),col_2
 * 
*/

static void
// gapfill_build_pathtarget2(PathTarget *pt_upper, PathTarget *pt_path, PathTarget *pt_subpath)
gapfill_build_pathtarget2(PathTarget *pt_upper, 	struct x_filler_context2*ctx)
{
	ListCell *lc;
	int i = -1;

	// create a copy which will be altered to become the new target
	// pt_upper=copy_pathtarget(pt_upper);

	foreach (lc, pt_upper->exprs)
	{
		i++;

		Expr *expr = lfirst(lc);
		Index	   sortgroupref=pt_upper->sortgrouprefs[i];

		ctx->sortgroupref=sortgroupref;

		Expr *new_expr=x_walker(expr,ctx);
		if(IsA(expr, FuncExpr) && is_gapfill_function_call(expr)) {
			ctx->gapfill_column_types=lappend_int(ctx->gapfill_column_types, TIME_COLUMN);
		}else {
			ctx->gapfill_column_types=lappend_int(ctx->gapfill_column_types, DERIVED_COLUMN);
		}
		
		add_column_to_pathtarget(ctx->project_cols, new_expr, sortgroupref);

	}
	
}

/*
 * Create a Gapfill Path node.
 *
 * The gap fill node needs rows to be sorted by time ASC
 * so we insert sort pathes if the query order does not match
 * that
 */
static Path *
gapfill_path_create(PlannerInfo *root, Path *subpath, FuncExpr *func)
{
	GapFillPath *path;

	path = (GapFillPath *) newNode(sizeof(GapFillPath), T_CustomPath);
	path->cpath.path.pathtype = T_CustomScan;
	path->cpath.methods = &gapfill_path_methods;
	

	/*
	 * parallel_safe must be false because it is not safe to execute this node
	 * in parallel, but it is safe for child nodes to be parallel
	 */
	Assert(!path->cpath.path.parallel_safe);
	path->cpath.path.rows = subpath->rows;
	path->cpath.path.parent = subpath->parent;
	path->cpath.path.param_info = subpath->param_info;
	path->cpath.flags = 0;
	path->cpath.path.pathkeys = subpath->pathkeys;

	// path->cpath.path.pathtarget = subpath->pathtarget;
	path->cpath.path.pathtarget = create_empty_pathtarget();
	subpath->pathtarget = create_empty_pathtarget();
	gapfill_build_pathtarget(root->upper_targets[UPPERREL_FINAL],
							 path->cpath.path.pathtarget,
							 subpath->pathtarget);

	struct x_filler_context2 ctx = {
		.aggregate_cols = subpath->pathtarget= create_empty_pathtarget(),
		.project_cols=path->cpath.path.pathtarget= create_empty_pathtarget(),
		.subpath_column_types=NULL,
		.gapfill_column_types=NULL,

	};
	// ctx.project_cols = pt_path;
	// ctx.aggregate_cols = pt_subpath;
	// ctx.subpath_column_types=NULL;
	// ctx.gapfill_column_types=NULL;

	gapfill_build_pathtarget2(root->upper_targets[UPPERREL_FINAL], &ctx);

	path->gapfill_column_types=ctx.gapfill_column_types;
	path->subpath_column_types=ctx.subpath_column_types;

	if (!gapfill_correct_order(root, subpath, func))
	{
		List *new_order = NIL;
		ListCell *lc;
		PathKey *pk_func = NULL;

		/* subpath does not have correct order */
		foreach (lc, root->group_pathkeys)
		{
			PathKey *pk = lfirst(lc);
			EquivalenceMember *em = linitial(pk->pk_eclass->ec_members);

			if (!pk_func && IsA(em->em_expr, FuncExpr) &&
				((FuncExpr *) em->em_expr)->funcid == func->funcid)
			{
				if (BTLessStrategyNumber == pk->pk_strategy)
					pk_func = pk;
				else
					pk_func = make_canonical_pathkey(root,
													 pk->pk_eclass,
													 pk->pk_opfamily,
													 BTLessStrategyNumber,
													 pk->pk_nulls_first);
			}
			else
				new_order = lappend(new_order, pk);
		}
		if (!pk_func)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("no top level time_bucket_gapfill in group by clause")));

		new_order = lappend(new_order, pk_func);
		subpath = (Path *)
			create_sort_path(root, subpath->parent, subpath, new_order, root->limit_tuples);
	}

	path->cpath.path.startup_cost = subpath->startup_cost;
	path->cpath.path.total_cost = subpath->total_cost;
	path->cpath.path.pathkeys = subpath->pathkeys;
	path->cpath.custom_paths = list_make1(subpath);
	path->func = func;

	return &path->cpath.path;
}

/*
 * Prepend GapFill node to every group_rel path.
 * The implementation assumes that TimescaleDB planning hook is called only once
 * per grouping.
 */
void
plan_add_gapfill(PlannerInfo *root, RelOptInfo *group_rel)
{
	ListCell *lc;
	Query *parse = root->parse;
	gapfill_walker_context context = { .call.node = NULL, .count = 0 };

	if (CMD_SELECT != parse->commandType || parse->groupClause == NIL)
		return;

	/*
	 * Look for time_bucket_gapfill function call in the target list, which
	 * will succeed on every call to plan_add_gapfill, thus it will lead to
	 * incorrect query plan if plan_add_gapfill is called more than once per
	 * grouping.
	 */
	gapfill_function_walker((Node *) parse->targetList, &context);

	if (context.count == 0)
		return;

	if (context.count > 1)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("multiple time_bucket_gapfill calls not allowed")));

	if (context.count == 1)
	{
		List *copy = group_rel->pathlist;
		group_rel->pathlist = NIL;
		group_rel->cheapest_total_path = NULL;
		group_rel->cheapest_startup_path = NULL;
		group_rel->cheapest_unique_path = NULL;

		/* Parameterized paths pathlist is currently deleted instead of being processed */
		list_free(group_rel->ppilist);
		group_rel->ppilist = NULL;

		list_free(group_rel->cheapest_parameterized_paths);
		group_rel->cheapest_parameterized_paths = NULL;

		foreach (lc, copy)
		{
			add_path(group_rel, gapfill_path_create(root, lfirst(lc), context.call.func));
		}
		group_rel->reltarget = ((Path *) list_nth(group_rel->pathlist, 0))->pathtarget;
		list_free(copy);
	}
}

static inline bool
is_gapfill_path(Path *path)
{
	return IsA(path, CustomPath) && castNode(CustomPath, path)->methods == &gapfill_path_methods;
}

/*
 * Since we construct the targetlist for the gapfill node from the
 * final targetlist we need to adjust any intermediate targetlists
 * between toplevel window agg node and gapfill node. This adjustment
 * is only necessary if multiple WindowAgg nodes are present.
 * In that case we need to adjust the targetlists of nodes between
 * toplevel WindowAgg node and Gapfill node
 *
 * Gapfill plan with multiple WindowAgg nodes:
 *
 *  WindowAgg
 *    ->  WindowAgg
 *          ->  Custom Scan (GapFill)
 *                ->  Sort
 *                      Sort Key: (time_bucket_gapfill(1, "time"))
 *                      ->  HashAggregate
 *                            Group Key: time_bucket_gapfill(1, "time")
 *                            ->  Seq Scan on metrics_int
 *
 */
void
gapfill_adjust_window_targetlist(PlannerInfo *root, RelOptInfo *input_rel, RelOptInfo *output_rel)
{
	ListCell *lc;

	if (!is_gapfill_path(linitial(input_rel->pathlist)))
		return;

	foreach (lc, output_rel->pathlist)
	{
		WindowAggPath *toppath = lfirst(lc);

		/*
		 * the toplevel WindowAggPath has the highest index. If winref is
		 * 1 we only have one WindowAggPath if its greater then 1 then there
		 * are multiple WindowAgg nodes.
		 *
		 * we skip toplevel WindowAggPath because targetlist of toplevel WindowAggPath
		 * is our starting point for building gapfill targetlist so we don't need to
		 * adjust the toplevel targetlist
		 */
		if (IsA(toppath, WindowAggPath) && toppath->winclause->winref > 1)
		{
			WindowAggPath *path;

			for (path = (WindowAggPath *) toppath->subpath; IsA(path, WindowAggPath);
				 path = (WindowAggPath *) path->subpath)
			{
				PathTarget *pt_top = toppath->path.pathtarget;
				PathTarget *pt;
				ListCell *lc_expr;
				int i = -1;

				pt = create_empty_pathtarget();
				/*
				 * for each child we build targetlist based on top path
				 * targetlist
				 */
				foreach (lc_expr, pt_top->exprs)
				{
					gapfill_walker_context context;
					i++;

					gapfill_expression_walker(lfirst(lc_expr), window_function_walker, &context);

					/*
					 * we error out on multiple window functions per resultset column
					 * when building gapfill node targetlist so we only assert here
					 */
					Assert(context.count <= 1);

					if (context.count == 1)
					{
						if (context.call.window->winref <= path->winclause->winref)
							/*
							 * window function of current level or below
							 * so we can put in verbatim
							 */
							add_column_to_pathtarget(pt, lfirst(lc_expr), pt_top->sortgrouprefs[i]);
						else if (context.call.window->args != NIL)
						{
							ListCell *lc_arg;
							if (list_length(context.call.window->args) > 1)
								/*
								 * check arguments past first argument dont have Vars
								 */
								for (lc_arg = lnext_compat(context.call.window->args,
														   list_head(context.call.window->args));
									 lc_arg != NULL;
									 lc_arg = lnext_compat(context.call.window->args, lc_arg))
								{
									if (contain_var_clause(lfirst(lc_arg)))
										ereport(ERROR,
												(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
												 errmsg("window functions with multiple column "
														"references not supported")));
								}

							if (contain_var_clause(linitial(context.call.window->args)))
								add_column_to_pathtarget(pt,
														 linitial(context.call.window->args),
														 pt_top->sortgrouprefs[i]);
						}
					}
					else
						add_column_to_pathtarget(pt, lfirst(lc_expr), pt_top->sortgrouprefs[i]);
				}
				path->path.pathtarget = pt;
			}
		}
	}
}
